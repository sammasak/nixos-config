//! The queue against a real PostgreSQL, one throwaway cluster per test: initdb into a temporary directory, a server
//! on a Unix socket in it with no TCP listener, stopped and deleted when the test ends. `initdb`, `postgres` and
//! `pg_ctl` must be on PATH; without them every test fails, never skips.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::arithmetic_side_effects,
    clippy::panic,
    reason = "the fixture's helpers: a failure there is the test failing"
)]

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use exec_pool::queue::{
    Arm, Logs, METRICS_UNAVAILABLE, Park, QueueError, Store, Submitted, TIMEOUTS_IN_A_ROW,
    TRANSCRIPT_BYTES, Transcript, Turn, TurnLog,
};
use exec_pool::task_result::{TaskResult, Usage};
use exec_pool::wake::Wake;
use exec_pool::{
    Agent, CheckpointRef, Error, Event, Kind, Outcome, ParkReason, Pins, Receipt, Resolution,
    SchemaVersion, Settle, Slot, SlotState, Status, TaskSpec,
};
use postgres::{Client, NoTls};
use serde_json::json;

static CLUSTERS: AtomicUsize = AtomicUsize::new(0);

struct Pg {
    root: PathBuf,
    server: Option<Child>,
}

impl Pg {
    fn new() -> Self {
        let n = CLUSTERS.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!("exec-pool-pg-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let ok = Command::new("initdb")
            .args([
                "-U",
                "exec_pool",
                "--auth=trust",
                "--no-sync",
                "-E",
                "UTF8",
                "--locale=C",
                "-D",
            ])
            .arg(root.join("data"))
            .stdout(Stdio::null())
            .status()
            .expect("initdb on PATH")
            .success();
        assert!(ok, "initdb failed");
        let mut pg = Self { root, server: None };
        pg.start();
        // what homelab.postgresql.clients and remoteClients create before migrate grants to them
        pg.sql()
            .batch_execute("CREATE ROLE exec_pool_submit LOGIN; CREATE ROLE exec_pool_runner LOGIN")
            .unwrap();
        pg
    }

    fn start(&mut self) {
        let server = Command::new("postgres")
            .arg("-D")
            .arg(self.root.join("data"))
            .arg("-k")
            .arg(&self.root)
            .args(["-c", "listen_addresses=", "-c", "fsync=off"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("postgres on PATH");
        self.server = Some(server);
        let deadline = Instant::now() + Duration::from_secs(30);
        while Client::connect(&self.conninfo(), NoTls).is_err() {
            assert!(Instant::now() < deadline, "postgres did not start");
            thread::sleep(Duration::from_millis(50));
        }
    }

    fn stop(&mut self) {
        let ok = Command::new("pg_ctl")
            .args(["-m", "fast", "-w", "stop", "-D"])
            .arg(self.root.join("data"))
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(ok, "pg_ctl stop failed");
        if let Some(mut s) = self.server.take() {
            s.wait().unwrap();
        }
    }

    /// A wrong claim that waits on a locked row errors after `lock_timeout` instead of hanging the test.
    fn conninfo(&self) -> String {
        format!(
            "host={} dbname=postgres user=exec_pool options='-c lock_timeout=5s'",
            self.root.display()
        )
    }

    fn store(&self) -> Store {
        Store::open(&self.conninfo()).unwrap()
    }

    fn migrated(&self) -> Store {
        let mut s = self.store();
        s.migrate().unwrap();
        s
    }

    fn sql(&self) -> Client {
        Client::connect(&self.conninfo(), NoTls).unwrap()
    }
}

impl Drop for Pg {
    fn drop(&mut self) {
        if self.server.is_some() {
            let _ = Command::new("pg_ctl")
                .args(["-m", "immediate", "-w", "stop", "-D"])
                .arg(self.root.join("data"))
                .stdout(Stdio::null())
                .status();
            if let Some(mut s) = self.server.take() {
                let _ = s.wait();
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

const ARGV_MARKER: &str = "prompt-text-that-must-stay-in-tasks";

fn task(id: &str, max_attempts: u32) -> TaskSpec {
    let v = json!({
        "schema_version": 1, "id": id, "idempotency_key": format!("key-{id}"),
        "source": { "repo": "sammasak/nixos-config", "rev": "6266701" },
        "command": { "agent": "none", "argv": ["echo", ARGV_MARKER], "workdir": "pkgs/exec-pool/secret-path" },
        "capabilities": ["read_only"], "resource_class": "small", "credential_class": "none",
        "retry": { "max_attempts": max_attempts }
    });
    TaskSpec::parse(&v.to_string(), &BTreeSet::from(["read_only".to_owned()])).unwrap()
}

fn slot(id: &str) -> Slot {
    Slot {
        schema_version: SchemaVersion::CURRENT,
        host: "msi-ms7758".to_owned(),
        id: id.to_owned(),
        state: SlotState::Idle,
        capabilities: BTreeSet::from(["read_only".to_owned()]),
        agents: BTreeSet::from([Agent::None]),
        pins: Pins::default(),
    }
}

fn submit(s: &mut Store, t: &TaskSpec) -> String {
    match s.submit(t).unwrap() {
        Submitted::New { attempt, .. } => attempt,
        Submitted::Duplicate { .. } => panic!("{} was already queued", t.id),
    }
}

const fn ev(epoch: u64, kind: Kind) -> Event {
    Event { epoch, kind }
}

fn receipt(attempt: &str, task: &str, epoch: u64, outcome: &str) -> Receipt {
    Receipt::parse(
        &json!({
            "schema_version": 1, "task_id": task, "attempt_id": attempt, "lease_epoch": epoch,
            "outcome": outcome, "effects": [{ "kind": "github_pr", "id": "sammasak/nixos-config#651" }],
            "checkpoint": { "schema_version": 1, "uri": "checkpoint://t/1", "digest": "sha256-x" }
        })
        .to_string(),
    )
    .unwrap()
}

/// Moves an attempt's lease deadline into the past, as the clock would; the write names its epoch like any other.
fn overdue(pg: &Pg, attempt: &str) {
    let n = pg
        .sql()
        .execute(
            "UPDATE attempts SET lease_deadline = now() - interval '1 second', fence = lease_epoch WHERE id = $1",
            &[&attempt],
        )
        .unwrap();
    assert_eq!(n, 1);
}

fn status(pg: &Pg, attempt: &str) -> (String, i64) {
    let row = pg
        .sql()
        .query_one(
            "SELECT status, lease_epoch FROM attempts WHERE id = $1",
            &[&attempt],
        )
        .unwrap();
    (row.get(0), row.get(1))
}

#[test]
fn migration_goes_up_down_and_up_and_refuses_a_newer_schema() {
    let pg = Pg::new();
    let mut s = pg.store();
    assert!(matches!(s.migrate_down(), Err(QueueError::NotMigrated)));
    s.migrate().unwrap();
    s.migrate().unwrap();
    let tables = |c: &mut Client| -> i64 {
        c.query_one(
            "SELECT count(*) FROM pg_tables WHERE tablename IN ('tasks', 'attempts', 'events', 'receipts', 'results')",
            &[],
        )
        .unwrap()
        .get(0)
    };
    assert_eq!(tables(&mut pg.sql()), 5);
    s.migrate_down().unwrap();
    assert_eq!(tables(&mut pg.sql()), 0);
    // a database at migration 1 takes the rest
    pg.sql().batch_execute(exec_pool::queue::UP).unwrap();
    s.migrate().unwrap();
    let version: i32 = pg
        .sql()
        .query_one("SELECT max(version) FROM schema_migrations", &[])
        .unwrap()
        .get(0);
    assert_eq!(version, 28);
    submit(&mut s, &task("t-1", 1));
    // a newer binary's additive migration keeps the floor: this one still serves the database, as after a rollback
    pg.sql()
        .execute(
            "INSERT INTO schema_migrations (version, floor) VALUES (29, 28)",
            &[],
        )
        .unwrap();
    s.migrate().unwrap();
    assert!(s.claim(&slot("s0"), 60).unwrap().is_some());
    // one this binary would misread, or one that names no floor, is refused
    pg.sql()
        .execute("INSERT INTO schema_migrations (version) VALUES (30)", &[])
        .unwrap();
    assert!(matches!(s.migrate(), Err(QueueError::SchemaAhead(30))));
    pg.sql()
        .execute(
            "UPDATE schema_migrations SET floor = 30 WHERE version = 30",
            &[],
        )
        .unwrap();
    assert!(matches!(s.migrate(), Err(QueueError::SchemaAhead(30))));
    assert!(matches!(s.migrate_down(), Err(QueueError::SchemaAhead(30))));
}

#[test]
fn a_database_that_took_0008_before_0007_takes_0007_and_its_floor() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    // as on a host deployed with 0008 before the quarantine landed: 0007 undone, 0008 kept
    pg.sql()
        .batch_execute(
            "DROP TABLE quarantined_slots; DELETE FROM schema_migrations WHERE version = 7; \
             ALTER TABLE schema_migrations DROP COLUMN floor",
        )
        .unwrap();
    s.migrate().unwrap();
    let floors: Vec<(i32, Option<i32>)> = pg
        .sql()
        .query(
            "SELECT version, floor FROM schema_migrations ORDER BY version",
            &[],
        )
        .unwrap()
        .iter()
        .map(|r| (r.get(0), r.get(1)))
        .collect();
    assert_eq!(
        floors.iter().find(|f| f.0 == 8),
        Some(&(8, None)),
        "0008 names no floor: it counts as 8"
    );
    assert!(floors.contains(&(7, Some(6))));
    s.quarantine(&slot("s0"), "refused").unwrap();
}

#[test]
fn a_quarantined_slot_shows_in_the_metrics_until_its_runner_clears_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let has = |text: &str, line: &str| text.lines().any(|l| l == line);
    // an empty claim registers the slot's host, whose series are then present at zero
    assert!(owner.claim(&slot("s0"), 60).unwrap().is_none());
    assert!(has(
        &owner.metrics().unwrap(),
        "exec_pool_slots{host=\"msi-ms7758\",state=\"quarantined\"} 0"
    ));
    // the remote slot's role writes it, and a second refusal only updates the reason
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_runner ");
    let mut runner = Store::open(&conninfo).unwrap();
    runner
        .quarantine(&slot("s0"), "an agent is running")
        .unwrap();
    runner
        .quarantine(&slot("s0"), &"unpushed work ".repeat(200))
        .unwrap();
    runner
        .quarantine(&slot("s1"), "an agent is running")
        .unwrap();
    assert!(has(
        &owner.metrics().unwrap(),
        "exec_pool_slots{host=\"msi-ms7758\",state=\"quarantined\"} 2"
    ));
    let reason: String = pg
        .sql()
        .query_one(
            "SELECT reason FROM quarantined_slots WHERE slot = 's0'",
            &[],
        )
        .unwrap()
        .get(0);
    assert_eq!(reason.chars().count(), 1024);
    assert!(reason.starts_with("unpushed work"));
    runner.clear_quarantine(&slot("s0")).unwrap();
    runner.clear_quarantine(&slot("s0")).unwrap();
    assert!(has(
        &owner.metrics().unwrap(),
        "exec_pool_slots{host=\"msi-ms7758\",state=\"quarantined\"} 1"
    ));
}

/// The one shape `submit_task` takes: what `exec-pool submit` builds.
fn agent_task() -> serde_json::Value {
    json!({
        "schema_version": 1, "id": "ignored", "idempotency_key": "cli:1",
        "source": { "repo": "https://github.com/sammasak/nixos-config.git", "rev": "6266701" },
        "command": { "agent": "claude", "argv": [ARGV_MARKER, "opus"], "workdir": "pkgs/exec-pool" },
        "capabilities": [], "resource_class": "small", "credential_class": "slot",
        "retry": { "max_attempts": 1 }
    })
}

#[test]
fn the_submitter_queues_through_submit_task_and_reads_no_prompt() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let task: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    let (id, duplicate) = s.submit_task(&task, 0).unwrap();
    assert!(id.starts_with("cli-") && !duplicate, "{id}");
    assert_eq!(s.submit_task(&task, 0).unwrap(), (id.clone(), true));
    let mut other = task.clone();
    other.command.argv.pop();
    assert!(s.submit_task(&other, 0).is_err(), "a key names one task");
    let shown = s.task(&id).unwrap().unwrap();
    assert_eq!(shown["status"], "queued");
    assert!(!shown.to_string().contains(ARGV_MARKER), "{shown}");
    assert_eq!(s.tasks(5).unwrap().len(), 1);
    // what it queued is a task the owner's claim decodes
    let claim = owner.claim(&claude_slot(), 60).unwrap().unwrap();
    assert_eq!(claim.task.id, id);

    let mut c = Client::connect(&conninfo, NoTls).unwrap();
    let refused = |c: &mut Client, sql: &str, code: &str| {
        let e = c.batch_execute(sql).unwrap_err();
        assert_eq!(
            e.code().map(postgres::error::SqlState::code),
            Some(code),
            "{sql}: {e}"
        );
    };
    for sql in [
        "INSERT INTO events (task_id, attempt_id, lease_epoch, to_status, reason, in_state_ms, since_submit_ms) \
         SELECT task_id, id, 0, 'failed', 'x', 0, 0 FROM attempts",
        "INSERT INTO tasks (id, idempotency_key, spec, max_attempts) VALUES ('x', 'x', '{}', 9)",
        "UPDATE attempts SET status = 'succeeded'",
        "SELECT spec FROM tasks",
        "SELECT * FROM receipts",
    ] {
        refused(&mut c, sql, "42501");
    }
    let bad: [(&str, serde_json::Value); 12] = [
        ("/capabilities", json!(["read_only"])),
        ("/capabilities", json!(["monitoring", "github"])),
        ("/capabilities", json!([1])),
        ("/capabilities", json!("github")),
        ("/capabilities", json!(["github", "github"])),
        ("/credential_class", json!("root")),
        ("/retry", json!({ "max_attempts": 9 })),
        ("/command/agent", json!("none")),
        ("/command/workdir", json!("a/../../x")),
        ("/source/rev", json!("--upload-pack=x")),
        ("/source/repo", json!("file:///etc")),
        ("/command/argv", json!(["p", "-m"])),
    ];
    for (at, v) in bad {
        let mut t = agent_task();
        *t.pointer_mut(at).unwrap() = v;
        refused(&mut c, &format!("SELECT submit_task('{t}')"), "22023");
    }
    let mut extra = agent_task();
    extra["command"]["env"] = json!({});
    refused(&mut c, &format!("SELECT submit_task('{extra}')"), "22023");
    refused(&mut c, "SELECT submit_task('[]')", "22023");
}

#[test]
fn submit_task_refuses_an_agent_no_slot_seen_in_the_last_day_offers() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let pi = |key: &str| {
        let mut t = agent_task();
        t["idempotency_key"] = json!(key);
        t["command"]["agent"] = json!("pi");
        serde_json::from_value::<TaskSpec>(t).unwrap()
    };
    let refusal = |s: &mut Store, t: &TaskSpec| match s.submit_task(t, 0) {
        Err(QueueError::Db { code, message }) => (code, message),
        other => panic!("{other:?}"),
    };
    let (code, message) = refusal(&mut s, &pi("cli:no-slot"));
    assert_eq!(code, "22023");
    assert!(
        message.contains("offers agent pi") && message.contains("offered: nothing"),
        "{message}"
    );
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
    let (_, message) = refusal(&mut s, &pi("cli:claude-only"));
    assert!(message.contains("offered: claude"), "{message}");
    assert!(
        s.tasks(5).unwrap().is_empty(),
        "a refused task leaves no row"
    );
    // a slot's next claim records the agents it offers now
    let mut both = claude_slot();
    both.agents.insert(Agent::Pi);
    assert!(owner.claim(&both, 60).unwrap().is_none());
    s.submit_task(&pi("cli:pi"), 0).unwrap();
    // a slot not seen for a day offers nothing
    pg.sql()
        .batch_execute("UPDATE slots SET seen_at = now() - interval '25 hours'")
        .unwrap();
    let (_, message) = refusal(&mut s, &pi("cli:stale"));
    assert!(message.contains("offered: nothing"), "{message}");
    let mut raw = Client::connect(&conninfo, NoTls).unwrap();
    for sql in [
        "SELECT submit_task_shaped('{}')",
        "INSERT INTO slots (host, id, agents) VALUES ('x', 'x', '[\"pi\"]')",
    ] {
        let e = raw.batch_execute(sql).unwrap_err();
        assert_eq!(
            e.code().map(postgres::error::SqlState::code),
            Some("42501"),
            "{sql}: {e}"
        );
    }
}

#[test]
fn submit_task_refuses_a_capability_no_slot_seen_in_the_last_day_offers_with_the_agent() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let requiring = |key: &str, caps: &[&str]| {
        let mut t = agent_task();
        t["idempotency_key"] = json!(key);
        t["capabilities"] = json!(caps);
        serde_json::from_value::<TaskSpec>(t).unwrap()
    };
    let refusal = |s: &mut Store, t: &TaskSpec| match s.submit_task(t, 0) {
        Err(QueueError::Unoffered(message)) => message,
        other => panic!("{other:?}"),
    };
    let mut monitored = claude_slot();
    monitored.capabilities = BTreeSet::from(["monitoring".to_owned()]);
    assert!(owner.claim(&monitored, 60).unwrap().is_none());
    // a pi slot offering github does not offer it to a claude task
    let mut pi = slot("pool2");
    pi.agents = BTreeSet::from([Agent::Pi]);
    pi.capabilities = BTreeSet::from(["github".to_owned()]);
    assert!(owner.claim(&pi, 60).unwrap().is_none());
    let message = refusal(&mut s, &requiring("cli:github", &["github", "monitoring"]));
    assert!(
        message.contains("offers capability github with agent claude")
            && message.contains("offered: monitoring"),
        "{message}"
    );
    let mut github = claude_slot();
    github.id = "pool3".to_owned();
    github.capabilities = BTreeSet::from(["github".to_owned()]);
    assert!(owner.claim(&github, 60).unwrap().is_none());
    let message = refusal(&mut s, &requiring("cli:both", &["github", "monitoring"]));
    assert!(
        message.contains("github and monitoring together"),
        "{message}"
    );
    assert!(
        s.tasks(5).unwrap().is_empty(),
        "a refused task leaves no row"
    );
    // a requirement one slot offers queues, and a task with none as before
    let (id, duplicate) = s
        .submit_task(&requiring("cli:monitoring", &["monitoring"]), 0)
        .unwrap();
    assert!(!duplicate);
    assert_eq!(
        s.submit_task(&requiring("cli:monitoring", &["monitoring"]), 0)
            .unwrap(),
        (id, true),
        "the same task again under its key is the one queued"
    );
    s.submit_task(&requiring("cli:none", &[]), 0).unwrap();
    // a slot's next claim records the capabilities it offers now
    monitored.capabilities.clear();
    assert!(owner.claim(&monitored, 60).unwrap().is_some());
    assert!(owner.claim(&github, 60).unwrap().is_none());
    let message = refusal(&mut s, &requiring("cli:monitoring-2", &["monitoring"]));
    assert!(message.contains("offered: github"), "{message}");
    // a start_session refuses alike, and the submitter cannot make a slot offer one
    let session = requiring("cli:session", &["monitoring"]);
    assert!(matches!(
        s.start_session(&session, 0),
        Err(QueueError::Unoffered(_))
    ));
    let e = Client::connect(&conninfo, NoTls)
        .unwrap()
        .batch_execute("UPDATE slots SET capabilities = '[\"monitoring\"]'")
        .unwrap_err();
    assert_eq!(
        e.code().map(postgres::error::SqlState::code),
        Some("42501"),
        "{e}"
    );
}

#[test]
fn a_task_requiring_a_capability_is_claimed_only_by_a_slot_that_offers_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let mut plain = claude_slot();
    plain.capabilities.clear();
    let mut monitored = claude_slot();
    monitored.id = "pool2".to_owned();
    monitored.capabilities = BTreeSet::from(["monitoring".to_owned()]);
    assert!(owner.claim(&plain, 60).unwrap().is_none());
    assert!(owner.claim(&monitored, 60).unwrap().is_none());
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let mut t = agent_task();
    t["capabilities"] = json!(["monitoring"]);
    let (id, _) = s
        .submit_task(&serde_json::from_value(t).unwrap(), 0)
        .unwrap();
    assert!(
        owner.claim(&plain, 60).unwrap().is_none(),
        "a slot without the capability leaves it queued"
    );
    let claim = owner.claim(&monitored, 60).unwrap().unwrap();
    assert_eq!(claim.task.id, id);
    assert_eq!(
        claim.task.capabilities,
        BTreeSet::from(["monitoring".to_owned()])
    );
}

#[test]
fn a_task_requiring_a_host_is_claimed_only_by_that_hosts_slot_and_an_unknown_host_is_refused() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let mut msi = claude_slot();
    msi.capabilities = BTreeSet::from(["host-msi-ms7758".to_owned()]);
    let mut acer = claude_slot();
    acer.host = "acer-swift".to_owned();
    acer.capabilities = BTreeSet::from(["host-acer-swift".to_owned()]);
    assert!(owner.claim(&msi, 60).unwrap().is_none());
    assert!(owner.claim(&acer, 60).unwrap().is_none());
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let requiring = |key: &str, host: &str| {
        let mut t = agent_task();
        t["idempotency_key"] = json!(key);
        t["capabilities"] = json!([host]);
        serde_json::from_value::<TaskSpec>(t).unwrap()
    };
    match s.submit_task(&requiring("cli:lenovo", "host-lenovo"), 0) {
        Err(QueueError::Unoffered(message)) => assert!(
            message.contains("offers capability host-lenovo with agent claude")
                && message.contains("offered: host-acer-swift, host-msi-ms7758"),
            "{message}"
        ),
        other => panic!("{other:?}"),
    }
    let (id, _) = s
        .submit_task(&requiring("cli:acer", "host-acer-swift"), 0)
        .unwrap();
    assert!(
        owner.claim(&msi, 60).unwrap().is_none(),
        "msi's slot leaves a task for acer queued"
    );
    assert_eq!(owner.claim(&acer, 60).unwrap().unwrap().task.id, id);
}

#[test]
fn the_runner_claims_and_settles_and_writes_nothing_else() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_runner ");
    let mut runner = Store::open(&conninfo).unwrap();
    let a = submit(&mut owner, &task("t-1", 1));
    let b = submit(&mut owner, &task("t-2", 3));
    let claim = runner.claim(&slot("s0"), 60).unwrap().unwrap();
    assert!(!claim.task.command.argv.is_empty());
    assert!(
        runner
            .live_on(&slot("s0"))
            .unwrap()
            .is_some_and(|l| l.id == a)
    );
    runner.apply(&a, &ev(1, Kind::Start), None).unwrap();
    runner.heartbeat(&a, 1, 60).unwrap();
    runner.apply(&a, &ev(1, Kind::Checkpoint), None).unwrap();
    let done = ev(1, Kind::Settle(Settle::Succeeded));
    runner
        .apply(&a, &done, Some(&receipt(&a, "t-1", 1, "succeeded")))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "succeeded");
    let out = |exit: i32, output: &str| TaskResult::new(None, Some(exit), output);
    let mut pushed = out(0, "done");
    pushed.branch = Some("pool/t-1".to_owned());
    pushed.head = Some("1f2e".repeat(10));
    assert!(runner.record_result(&a, 1, &pushed).unwrap());
    assert!(!runner.record_result(&a, 1, &out(0, "again")).unwrap());
    // the commit it pushed, which a merged pull request's head is held to (exec-pool sessions' rescued)
    let head: Option<String> = pg
        .sql()
        .query_one("SELECT head FROM results WHERE attempt_id = $1", &[&a])
        .unwrap()
        .get(0);
    assert_eq!(head, Some("1f2e".repeat(10)));
    runner.claim(&slot("s1"), 60).unwrap().unwrap();
    // a slot's next claim updates its row as this role
    assert!(runner.claim(&slot("s0"), 60).unwrap().is_none());
    overdue(&pg, &b);
    assert_eq!(runner.reconcile().unwrap().len(), 1);
    assert_eq!(status(&pg, &b).0, "queued");

    let mut raw = Client::connect(&conninfo, NoTls).unwrap();
    for sql in [
        "INSERT INTO tasks (id, idempotency_key, spec, max_attempts) VALUES ('x', 'x', '{}', 9)",
        "INSERT INTO attempts (id, task_id) VALUES ('x', 't-1')",
        "UPDATE tasks SET max_attempts = 9",
        "UPDATE attempts SET task_id = 't-2', fence = lease_epoch",
        "UPDATE attempts SET pins = '{}', fence = lease_epoch",
        "UPDATE events SET reason = 'x'",
        "DELETE FROM attempts",
        "DELETE FROM events",
        "DELETE FROM results",
        "UPDATE results SET attempt_id = 't-2.a'",
        "SELECT submit_task('{}')",
        "SELECT submit_task('{}', 0)",
        "UPDATE attempts SET cancel_requested = true, fence = lease_epoch",
        "SELECT cancel_task('t-1')",
        "DELETE FROM slots",
    ] {
        let e = raw.batch_execute(sql).unwrap_err();
        assert_eq!(
            e.code().map(postgres::error::SqlState::code),
            Some("42501"),
            "{sql}: {e}"
        );
    }
}

#[test]
fn a_tcp_address_is_refused() {
    for conninfo in [
        "host=localhost dbname=exec_pool",
        "host=/run/postgresql,127.0.0.1 dbname=exec_pool",
        "host=/run/postgresql hostaddr=10.0.0.5 dbname=exec_pool",
        "dbname=exec_pool",
    ] {
        assert!(
            matches!(Store::open(conninfo), Err(QueueError::NotUnixSocket)),
            "{conninfo}"
        );
    }
}

#[test]
fn the_cli_reaches_a_remote_queue_by_its_units_password_credential() {
    let dir = std::env::temp_dir().join(format!("exec-pool-cred-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cli = |conninfo: &str| {
        Command::new(env!("CARGO_BIN_EXE_exec-pool"))
            .arg("list")
            .env("EXEC_POOL_DB", conninfo)
            .env("CREDENTIALS_DIRECTORY", &dir)
            .output()
            .unwrap()
    };
    // another unit's credentials, no db-password: the socket, as without them (no database here: 75)
    let out = cli("host=/nonexistent dbname=exec_pool user=exec_pool");
    assert_eq!(out.status.code(), Some(75));
    // with the password, a socket conninfo is refused as open_remote refuses it, before any connection
    std::fs::write(dir.join("db-password"), "pw\n").unwrap();
    let out = cli("host=/run/postgresql dbname=exec_pool user=exec_pool_runner");
    assert_eq!(out.status.code(), Some(1));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_remote_queue_is_tcp_with_the_password_apart() {
    let tcp = "host=192.168.10.110 port=5432 dbname=exec_pool user=exec_pool_runner";
    assert!(Store::open_remote(tcp, b"pw").is_ok());
    for (conninfo, password) in [
        (tcp, &b""[..]),
        ("host=/run/postgresql dbname=exec_pool", b"pw"),
        (
            "host=/run/postgresql,192.168.10.110 dbname=exec_pool",
            b"pw",
        ),
        (
            "host=192.168.10.110 password=inline dbname=exec_pool",
            b"pw",
        ),
        ("dbname=exec_pool", b"pw"),
    ] {
        assert!(
            matches!(
                Store::open_remote(conninfo, password),
                Err(QueueError::NotRemote)
            ),
            "{conninfo}"
        );
    }
}

#[test]
fn a_claimer_skips_the_row_another_holds() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    let mut other = pg.sql();
    let mut tx = other.transaction().unwrap();
    tx.query(
        "SELECT id FROM attempts WHERE status = 'queued' FOR UPDATE",
        &[],
    )
    .unwrap();
    let started = Instant::now();
    assert!(s.claim(&slot("s0"), 60).unwrap().is_none());
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the claim waited on the lock"
    );
    tx.commit().unwrap();
    let claim = s.claim(&slot("s0"), 60).unwrap().unwrap();
    assert_eq!(
        (claim.attempt.id.as_str(), claim.attempt.lease_epoch),
        (a.as_str(), 1)
    );
}

#[test]
fn concurrent_claimers_get_one_lease() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    for round in 0..20 {
        submit(&mut s, &task(&format!("t-{round}"), 1));
        let barrier = Arc::new(Barrier::new(2));
        let won: Vec<bool> = (0..2)
            .map(|claimer| {
                let (barrier, conninfo) = (barrier.clone(), pg.conninfo());
                thread::spawn(move || {
                    let mut s = Store::open(&conninfo).unwrap();
                    s.migrate().unwrap();
                    barrier.wait();
                    s.claim(&slot(&format!("r{round}-c{claimer}")), 60)
                        .unwrap()
                        .is_some()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();
        assert_eq!(won.iter().filter(|w| **w).count(), 1, "round {round}");
    }

    // and many claimers over many tasks: each task leased exactly once
    for n in 0..40 {
        submit(&mut s, &task(&format!("m-{n}"), 1));
    }
    let barrier = Arc::new(Barrier::new(4));
    let mut leased: Vec<String> = (0..4)
        .map(|claimer| {
            let (barrier, conninfo) = (barrier.clone(), pg.conninfo());
            thread::spawn(move || {
                let mut s = Store::open(&conninfo).unwrap();
                barrier.wait();
                let mut got = Vec::new();
                for k in 0.. {
                    match s.claim(&slot(&format!("m-c{claimer}-{k}")), 60).unwrap() {
                        Some(c) => got.push(c.attempt.id),
                        None => break,
                    }
                }
                got
            })
        })
        .collect::<Vec<_>>()
        .into_iter()
        .flat_map(|h| h.join().unwrap())
        .collect();
    leased.sort();
    let unique: BTreeSet<_> = leased.iter().collect();
    assert_eq!((leased.len(), unique.len()), (40, 40));
}

#[test]
fn a_slot_holds_one_live_lease() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    submit(&mut s, &task("t-1", 1));
    submit(&mut s, &task("t-2", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    assert!(matches!(
        s.claim(&slot("s0"), 60),
        Err(QueueError::Db { code, .. }) if code == "23505"
    ));
    assert_eq!(
        status(&pg, "t-2.a").0,
        "queued",
        "the refused claim rolled back"
    );
}

#[test]
fn a_stale_epoch_is_refused_by_the_database() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 3));
    // holder 1's lease expires before it starts; holder 3 now holds the attempt
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    overdue(&pg, &a);
    assert_eq!(s.reconcile().unwrap().len(), 1);
    let second = s.claim(&slot("s1"), 60).unwrap().unwrap();
    assert_eq!(second.attempt.lease_epoch, 3);

    // the contract check
    assert!(matches!(
        s.apply(&a, &ev(1, Kind::Start), None),
        Err(QueueError::Contract(Error::StaleEpoch {
            got: 1,
            current: 3
        }))
    ));
    assert!(matches!(s.heartbeat(&a, 1, 60), Err(QueueError::Fenced(_))));
    // a writer that skipped that check: the database refuses it, with or without naming an epoch
    let mut c = pg.sql();
    for write in [
        "UPDATE attempts SET status = 'succeeded', lease_deadline = NULL, fence = 1 WHERE id = $1",
        "UPDATE attempts SET status = 'succeeded', lease_deadline = NULL WHERE id = $1",
        "UPDATE attempts SET lease_epoch = 9, fence = 3 WHERE id = $1",
    ] {
        let e = c.execute(write, &[&a]).unwrap_err();
        assert_eq!(
            e.as_db_error().map(|d| d.code().code()),
            Some("XP409"),
            "{write}"
        );
    }
    assert_eq!(status(&pg, &a), ("leased".to_owned(), 3));
    // the current holder still moves it
    s.apply(&a, &ev(3, Kind::Start), None).unwrap();

    // seeded break: without the trigger the same stale write lands, so the refusal above was the fence's
    c.batch_execute("DROP TRIGGER attempts_fence ON attempts")
        .unwrap();
    c.execute(
        "UPDATE attempts SET status = 'succeeded', lease_deadline = NULL, fence = 1 WHERE id = $1",
        &[&a],
    )
    .unwrap();
    assert_eq!(status(&pg, &a).0, "succeeded");
}

#[test]
fn an_expired_running_attempt_needs_review_and_is_never_released() {
    let mut pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 3));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    overdue(&pg, &a);
    // the holder whose deadline passed may not finish, even before the reconciler runs
    assert!(matches!(
        s.apply(&a, &ev(1, Kind::Checkpoint), None),
        Err(QueueError::NotLive(_))
    ));
    assert!(matches!(
        s.heartbeat(&a, 1, 60),
        Err(QueueError::NotLive(_))
    ));
    let changes = s.reconcile().unwrap();
    assert_eq!(changes.len(), 1);
    assert_eq!(
        (changes[0].to, changes[0].reason),
        (Status::NeedsReview, "lease_expired")
    );
    assert_eq!(status(&pg, &a), ("needs_review".to_owned(), 2));
    assert!(s.claim(&slot("s1"), 60).unwrap().is_none());
    // a server restart and a fresh start reconcile again and still leave the review alone
    drop(s);
    pg.stop();
    pg.start();
    let mut s = pg.migrated();
    assert!(s.reconcile().unwrap().is_empty());
    assert!(s.claim(&slot("s1"), 60).unwrap().is_none());
    assert_eq!(status(&pg, &a).0, "needs_review");
    // a stale holder cannot settle it; the operator resolves it explicitly
    assert!(matches!(
        s.apply(
            &a,
            &ev(1, Kind::Settle(Settle::Succeeded)),
            Some(&receipt(&a, "t-1", 1, "succeeded"))
        ),
        Err(QueueError::Contract(Error::StaleEpoch {
            got: 1,
            current: 2
        }))
    ));
    // nor may anyone expire or lease it through apply
    let elsewhere = exec_pool::Placement {
        host: "h".to_owned(),
        slot: "s".to_owned(),
    };
    for kind in [Kind::Expire, Kind::Lease(elsewhere)] {
        assert!(matches!(
            s.apply(&a, &ev(2, kind), None),
            Err(QueueError::Contract(Error::IllegalTransition { .. }))
        ));
    }
    let (back, change) = s
        .apply(&a, &ev(2, Kind::Resolve(Resolution::Queued)), None)
        .unwrap();
    assert_eq!((back.status, change.reason), (Status::Queued, "operator"));
    assert_eq!(
        s.claim(&slot("s1"), 60)
            .unwrap()
            .unwrap()
            .attempt
            .lease_epoch,
        3
    );
}

#[test]
fn a_duplicate_submission_returns_the_queued_task() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    assert_eq!(
        s.submit(&task("t-1", 1)).unwrap(),
        Submitted::Duplicate { attempt: a }
    );
    let mut other = task("t-2", 1);
    other.idempotency_key = "key-t-1".to_owned();
    assert!(matches!(
        s.submit(&other),
        Err(QueueError::Contract(Error::IdempotencyConflict(k))) if k == "key-t-1"
    ));
    let n: i64 = pg
        .sql()
        .query_one("SELECT count(*) FROM tasks", &[])
        .unwrap()
        .get(0);
    assert_eq!(n, 1);
}

#[test]
fn max_attempts_stop_retries() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 2));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    overdue(&pg, &a);
    assert_eq!(s.reconcile().unwrap()[0].to, Status::Queued);
    let second = s.claim(&slot("s0"), 60).unwrap().unwrap();
    assert_eq!(second.attempt.tries, 2);
    overdue(&pg, &a);
    let last = s.reconcile().unwrap();
    assert_eq!(
        (last[0].to, last[0].reason),
        (Status::Failed, "attempts_exhausted")
    );
    assert!(s.claim(&slot("s0"), 60).unwrap().is_none());

    // a retry the runner asks for counts the same way
    let b = submit(&mut s, &task("t-2", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    for kind in [Kind::Start, Kind::Checkpoint, Kind::Settle(Settle::Queued)] {
        s.apply(&b, &ev(1, kind), None).unwrap();
    }
    assert_eq!(status(&pg, &b).0, "failed");
}

#[test]
fn a_terminal_settle_needs_its_own_receipt() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    s.apply(&a, &ev(1, Kind::Checkpoint), None).unwrap();
    let done = ev(1, Kind::Settle(Settle::Succeeded));
    assert!(matches!(
        s.apply(&a, &done, None),
        Err(QueueError::Receipt(Status::Succeeded))
    ));
    assert!(matches!(
        s.apply(&a, &done, Some(&receipt(&a, "t-1", 1, "failed"))),
        Err(QueueError::Contract(Error::Receipt("outcome")))
    ));
    assert!(matches!(
        s.apply(
            &a,
            &ev(1, Kind::Settle(Settle::Waiting)),
            Some(&receipt(&a, "t-1", 1, "succeeded"))
        ),
        Err(QueueError::Receipt(Status::Waiting))
    ));
    assert_eq!(status(&pg, &a).0, "checkpointing");
    let (_, change) = s
        .apply(&a, &done, Some(&receipt(&a, "t-1", 1, "succeeded")))
        .unwrap();
    assert_eq!(change.to, Status::Succeeded);
    let row = pg
        .sql()
        .query_one(
            "SELECT e.to_status, r.lease_epoch, r.effects, a.checkpoint FROM receipts r \
             JOIN events e ON e.id = r.event_id JOIN attempts a ON a.id = r.attempt_id",
            &[],
        )
        .unwrap();
    assert_eq!(row.get::<_, &str>(0), "succeeded");
    assert_eq!(row.get::<_, i64>(1), 1);
    assert_eq!(
        row.get::<_, serde_json::Value>(2),
        json!([{ "kind": "github_pr", "id": "sammasak/nixos-config#651" }])
    );
    assert_eq!(
        row.get::<_, serde_json::Value>(3)["uri"],
        json!("checkpoint://t/1")
    );
    // a settled attempt never changes again, even for a writer naming its epoch
    let e = pg
        .sql()
        .execute(
            "UPDATE attempts SET status = 'queued', fence = lease_epoch WHERE id = $1",
            &[&a],
        )
        .unwrap_err();
    assert_eq!(e.as_db_error().map(|d| d.code().code()), Some("XP409"));
}

#[test]
fn a_settled_attempt_records_its_result_for_the_submitter() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 2));
    let out = |exit: i32, output: &str| TaskResult::new(None, Some(exit), output);
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    assert!(
        matches!(
            s.record_result(&a, 1, &out(1, "x")),
            Err(QueueError::Fenced(_))
        ),
        "not while it runs"
    );
    for kind in [Kind::Checkpoint, Kind::Settle(Settle::Queued)] {
        s.apply(&a, &ev(1, kind), None).unwrap();
    }
    assert!(s.record_result(&a, 1, &out(128, "clone failed")).unwrap());
    assert!(
        !s.record_result(&a, 1, &out(0, "again")).unwrap(),
        "once per epoch"
    );
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    for kind in [Kind::Start, Kind::Checkpoint] {
        s.apply(&a, &ev(2, kind), None).unwrap();
    }
    s.apply(
        &a,
        &ev(2, Kind::Settle(Settle::Succeeded)),
        Some(&receipt(&a, "t-1", 2, "succeeded")),
    )
    .unwrap();
    assert!(
        matches!(
            s.record_result(&a, 1, &out(1, "stale")),
            Err(QueueError::Fenced(_))
        ),
        "another epoch's"
    );
    // a re-leased attempt shows no earlier epoch's result
    assert!(s.result(&a).unwrap().unwrap()["result"].is_null());
    let mut done = TaskResult::new(Some(exec_pool::Outcome::Succeeded), Some(0), "opened PR #9");
    done.branch = Some("pool/t-1".to_owned());
    assert!(s.record_result(&a, 2, &done).unwrap());

    let submitter = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let shown = Store::open(&submitter)
        .unwrap()
        .result(&a)
        .unwrap()
        .unwrap();
    assert_eq!(shown["status"], "succeeded");
    assert_eq!(shown["result"]["lease_epoch"], 2);
    assert_eq!(shown["result"]["outcome"], "succeeded");
    assert_eq!(shown["result"]["exit_code"], 0);
    assert_eq!(shown["result"]["output"], "opened PR #9");
    assert_eq!(shown["result"]["branch"], "pool/t-1");
    assert!(!shown.to_string().contains(ARGV_MARKER), "{shown}");
    let e = Client::connect(&submitter, NoTls)
        .unwrap()
        .batch_execute("UPDATE results SET output = 'forged'")
        .unwrap_err();
    assert_eq!(e.code().map(postgres::error::SqlState::code), Some("42501"));
    let full = "é".repeat(exec_pool::task_result::OUTPUT_BYTES);
    let fresh = submit(&mut s, &task("t-3", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    for kind in [Kind::Start, Kind::Checkpoint, Kind::Settle(Settle::Queued)] {
        s.apply(&fresh, &ev(1, kind), None).unwrap();
    }
    assert!(
        s.record_result(
            &fresh,
            1,
            &TaskResult::new(None, None, &format!("\0{full}"))
        )
        .unwrap(),
        "the bound and the CHECK agree"
    );
    let fresh = submit(&mut s, &task("t-2", 1));
    assert!(s.result(&fresh).unwrap().unwrap()["result"].is_null());
}

#[test]
fn the_queue_survives_a_restart_and_says_when_the_database_is_down() {
    let mut pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();

    pg.stop();
    for result in [
        s.submit(&task("t-2", 1)).map(|_| ()),
        s.claim(&slot("s1"), 60).map(|_| ()),
        s.apply(&a, &ev(1, Kind::Start), None).map(|_| ()),
        s.reconcile().map(|_| ()),
        s.metrics().map(|_| ()),
    ] {
        assert!(
            matches!(result, Err(QueueError::Unavailable(_))),
            "{result:?}"
        );
    }

    pg.start();
    // the same store reconnects, and the lease taken before the outage is still there
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    assert_eq!(status(&pg, &a), ("running".to_owned(), 1));
    let n: i64 = pg
        .sql()
        .query_one("SELECT count(*) FROM tasks", &[])
        .unwrap()
        .get(0);
    assert_eq!(n, 1, "the submit refused during the outage left nothing");
}

#[test]
fn state_changes_and_metrics_keep_ids_and_prompts_where_they_belong() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    // no traffic: every state is present at zero, unlike the unavailable rendering
    let has = |text: &str, line: &str| text.lines().any(|l| l == line);
    let idle = s.metrics().unwrap();
    assert!(has(&idle, "exec_pool_queue_up 1"));
    let agents = ["none", "claude", "codex", "pi"];
    let states = [
        "queued",
        "leased",
        "running",
        "checkpointing",
        "waiting",
        "succeeded",
        "failed",
        "needs_review",
        "cancelled",
    ];
    for state in states {
        for agent in agents {
            assert!(
                has(
                    &idle,
                    &format!(
                        "exec_pool_attempts{{host=\"none\",state=\"{state}\",agent=\"{agent}\"}} 0"
                    )
                ),
                "{state} {agent}"
            );
        }
    }
    let series = |text: &str| {
        text.lines()
            .filter(|l| l.starts_with("exec_pool_attempts{"))
            .count()
    };
    assert_eq!(series(&idle), states.len() * agents.len());
    assert!(has(&idle, "exec_pool_queued_oldest_seconds 0"));
    assert_eq!(
        idle.strip_suffix("exec_pool_queue_up 1\n").map(|_| ()),
        None,
        "the up-1 rendering carries the series"
    );
    assert!(idle.starts_with(METRICS_UNAVAILABLE.trim_end_matches("exec_pool_queue_up 0\n")));

    let Submitted::New { attempt: a, change } = s.submit(&task("t-1", 1)).unwrap() else {
        panic!("not new");
    };
    assert_eq!(
        (change.from, change.to, change.reason),
        (None, Status::Queued, "submit")
    );
    let claim = s.claim(&slot("s0"), 60).unwrap().unwrap();
    let line = serde_json::to_value(&claim.change).unwrap();
    assert_eq!(
        line,
        json!({
            "task_id": "t-1", "attempt": a, "lease_epoch": 1, "host": "msi-ms7758", "slot": "s0",
            "from": "queued", "to": "leased", "reason": "lease",
            "durations": line["durations"].clone()
        })
    );
    assert!(line["durations"]["in_state_ms"].as_i64().unwrap() >= 0);
    assert!(line["durations"]["since_submit_ms"].as_i64().unwrap() >= 0);

    let text = s.metrics().unwrap();
    assert!(has(
        &text,
        "exec_pool_attempts{host=\"msi-ms7758\",state=\"leased\",agent=\"none\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_attempts{host=\"none\",state=\"queued\",agent=\"none\"} 0"
    ));
    // the claiming host's series beside the hostless ones
    assert_eq!(series(&text), 2 * states.len() * agents.len());
    assert!(has(
        &text,
        "exec_pool_transitions_total{host=\"msi-ms7758\",from=\"queued\",to=\"leased\",reason=\"lease\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_transitions_total{host=\"none\",from=\"none\",to=\"queued\",reason=\"submit\"} 1"
    ));
    // the host is a label; the slot, the task and the attempt are not
    for id in ["t-1", a.as_str(), "\"s0\"", ARGV_MARKER] {
        assert!(!text.contains(id), "{id} in the metrics");
    }
    // the history holds ids and states, never the prompt or the workdir
    let rows = pg
        .sql()
        .query("SELECT row_to_json(e)::text FROM events e", &[])
        .unwrap();
    assert_eq!(rows.len(), 2);
    for r in rows {
        let row: String = r.get(0);
        assert!(
            !row.contains(ARGV_MARKER) && !row.contains("secret-path"),
            "{row}"
        );
    }
}

#[test]
fn an_idle_queue_renders_slots_leases_and_durations_at_zero() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    assert!(
        !s.metrics().unwrap().contains("exec_pool_slots{"),
        "no host has claimed: nothing to split by"
    );
    assert!(s.claim(&slot("s0"), 60).unwrap().is_none());
    let idle = s.metrics().unwrap();
    let has = |line: &str| idle.lines().any(|l| l == line);
    assert!(has("exec_pool_slots{host=\"msi-ms7758\",state=\"busy\"} 0"));
    assert!(has("exec_pool_slots{host=\"msi-ms7758\",state=\"idle\"} 1"));
    assert!(has("exec_pool_slots_declared{host=\"msi-ms7758\"} 1"));
    assert!(has("exec_pool_queued_claimable_oldest_seconds 0"));
    for state in ["leased", "running", "checkpointing"] {
        assert!(has(&format!(
            "exec_pool_lease_overdue{{host=\"msi-ms7758\",state=\"{state}\"}} 0"
        )));
    }
    for agent in ["none", "claude", "codex", "pi"] {
        for h in ["exec_pool_queue_wait_seconds", "exec_pool_run_seconds"] {
            let at = format!("host=\"msi-ms7758\",agent=\"{agent}\"");
            assert!(has(&format!("{h}_count{{{at}}} 0")), "{h} {agent}");
            assert!(has(&format!("{h}_bucket{{{at},le=\"+Inf\"}} 0")));
            assert!(has(&format!("{h}_bucket{{{at},le=\"10\"}} 0")));
        }
    }
}

#[test]
fn a_wait_a_run_and_an_overdue_lease_show_in_the_metrics() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let has = |text: &str, line: &str| text.lines().any(|l| l == line);
    let a = submit(&mut s, &task("t-1", 2));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    let text = s.metrics().unwrap();
    assert!(has(
        &text,
        "exec_pool_slots{host=\"msi-ms7758\",state=\"busy\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_slots{host=\"msi-ms7758\",state=\"idle\"} 0"
    ));
    assert!(has(
        &text,
        "exec_pool_slots_declared{host=\"msi-ms7758\"} 1"
    ));
    // the wait was well under ten seconds: in every bucket, and counted once
    assert!(has(
        &text,
        "exec_pool_queue_wait_seconds_bucket{host=\"msi-ms7758\",agent=\"none\",le=\"10\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_queue_wait_seconds_count{host=\"msi-ms7758\",agent=\"none\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_queue_wait_seconds_count{host=\"msi-ms7758\",agent=\"claude\"} 0"
    ));
    assert!(has(
        &text,
        "exec_pool_lease_overdue{host=\"msi-ms7758\",state=\"leased\"} 0"
    ));
    // a two-minute wait: above le=60, inside le=300
    pg.sql()
        .execute(
            "UPDATE events SET in_state_ms = 120000 WHERE from_status = 'queued'",
            &[],
        )
        .unwrap();
    let text = s.metrics().unwrap();
    for line in [
        "exec_pool_queue_wait_seconds_bucket{host=\"msi-ms7758\",agent=\"none\",le=\"60\"} 0",
        "exec_pool_queue_wait_seconds_bucket{host=\"msi-ms7758\",agent=\"none\",le=\"300\"} 1",
        "exec_pool_queue_wait_seconds_sum{host=\"msi-ms7758\",agent=\"none\"} 120",
    ] {
        assert!(has(&text, line), "{line}");
    }
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    s.apply(&a, &ev(1, Kind::Checkpoint), None).unwrap();
    let text = s.metrics().unwrap();
    assert!(has(
        &text,
        "exec_pool_run_seconds_count{host=\"msi-ms7758\",agent=\"none\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_run_seconds_bucket{host=\"msi-ms7758\",agent=\"none\",le=\"10\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_lease_overdue{host=\"msi-ms7758\",state=\"checkpointing\"} 0"
    ));

    // a dead runner: the lease is past its deadline and nothing has reconciled it yet
    overdue(&pg, &a);
    let text = s.metrics().unwrap();
    assert!(has(
        &text,
        "exec_pool_lease_overdue{host=\"msi-ms7758\",state=\"checkpointing\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_slots{host=\"msi-ms7758\",state=\"busy\"} 1"
    ));

    assert_eq!(s.reconcile().unwrap().len(), 1);
    let text = s.metrics().unwrap();
    assert!(has(
        &text,
        "exec_pool_lease_overdue{host=\"msi-ms7758\",state=\"checkpointing\"} 0"
    ));
    assert!(has(
        &text,
        "exec_pool_slots{host=\"msi-ms7758\",state=\"busy\"} 0"
    ));
    assert!(has(
        &text,
        "exec_pool_attempts{host=\"msi-ms7758\",state=\"needs_review\",agent=\"none\"} 1"
    ));
    assert!(has(
        &text,
        "exec_pool_transitions_total{host=\"msi-ms7758\",from=\"checkpointing\",to=\"needs_review\",reason=\"lease_expired\"} 1"
    ));
}

#[test]
fn a_heartbeat_keeps_the_lease_alive() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    assert!(matches!(
        s.claim(&slot("s0"), 0),
        Err(QueueError::Range("lease_secs"))
    ));
    s.claim(&slot("s0"), 1).unwrap().unwrap();
    s.apply(&a, &ev(1, Kind::Start), None).unwrap();
    let remaining = |pg: &Pg| -> f64 {
        pg.sql()
            .query_one(
                "SELECT extract(epoch FROM lease_deadline - now())::float8 FROM attempts WHERE id = $1",
                &[&a],
            )
            .unwrap()
            .get(0)
    };
    assert!(remaining(&pg) <= 1.0);
    assert!(!s.heartbeat(&a, 1, 3600).unwrap());
    assert!(remaining(&pg) > 3000.0);
    thread::sleep(Duration::from_millis(1100));
    assert!(s.reconcile().unwrap().is_empty());
    // only the reconciler expires a lease, and only an overdue one
    assert!(matches!(
        s.apply(&a, &ev(1, Kind::Expire), None),
        Err(QueueError::Contract(Error::IllegalTransition { .. }))
    ));
    assert_eq!(status(&pg, &a), ("running".to_owned(), 1));
}

/// A store as `exec_pool_submit`, and the task it queued through `submit_task`.
fn submitter(pg: &Pg) -> (Store, String) {
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    assert!(pg.store().claim(&claude_slot(), 60).unwrap().is_none());
    let task: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    let (id, _) = s.submit_task(&task, 0).unwrap();
    (s, id)
}

fn claude_slot() -> Slot {
    let mut claude = slot("pool1");
    claude.agents = BTreeSet::from([Agent::Claude]);
    claude
}

#[test]
fn the_submitter_cancels_its_own_queued_task_at_once_and_no_other() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = submitter(&pg);
    let theirs = submit(&mut owner, &task("t-1", 1));
    let attempt = format!("{id}.a");
    assert_eq!(s.cancel(&id).unwrap(), (attempt.clone(), Status::Cancelled));
    assert_eq!(status(&pg, &attempt), ("cancelled".to_owned(), 0));
    assert_eq!(
        s.cancel(&attempt).unwrap(),
        (attempt.clone(), Status::Cancelled),
        "a second cancel changes nothing"
    );
    let reasons: Vec<String> = pg
        .sql()
        .query(
            "SELECT reason FROM events WHERE attempt_id = $1 ORDER BY id",
            &[&attempt],
        )
        .unwrap()
        .iter()
        .map(|r| r.get(0))
        .collect();
    assert_eq!(reasons, ["submit", "cancelled"]);
    assert!(
        matches!(s.cancel(&theirs), Err(QueueError::NotFound(_))),
        "a task another role queued"
    );
    assert!(matches!(s.cancel("nope"), Err(QueueError::NotFound(_))));
    assert_eq!(status(&pg, &theirs), ("queued".to_owned(), 0));
    // cancelled is settled: nothing claims, wakes or rewrites it
    let claim = owner.claim(&claude_slot(), 60).unwrap();
    assert!(claim.is_none(), "{claim:?}");
    assert!(owner.apply(&attempt, &ev(0, Kind::Wake), None).is_err());
    let e = pg
        .sql()
        .execute(
            "UPDATE attempts SET status = 'queued', fence = lease_epoch WHERE id = $1",
            &[&attempt],
        )
        .unwrap_err();
    assert_eq!(e.code().map(postgres::error::SqlState::code), Some("XP409"));
}

#[test]
fn a_running_task_is_cancelled_by_its_runner_at_the_next_heartbeat() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = submitter(&pg);
    let claim = owner.claim(&claude_slot(), 60).unwrap().unwrap();
    let a = claim.attempt.id;
    owner.apply(&a, &ev(1, Kind::Start), None).unwrap();
    assert!(!owner.heartbeat(&a, 1, 60).unwrap());
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Running));
    assert!(
        owner.heartbeat(&a, 1, 60).unwrap(),
        "the runner reads the mark"
    );
    assert!(
        matches!(owner.heartbeat(&a, 0, 60), Err(QueueError::Fenced(_))),
        "a stale holder renews nothing"
    );
    assert_eq!(status(&pg, &a), ("running".to_owned(), 1));
    owner.apply(&a, &ev(1, Kind::Checkpoint), None).unwrap();
    let r = receipt(&a, &id, 1, "succeeded");
    assert!(matches!(
        owner.apply(&a, &ev(1, Kind::Settle(Settle::Cancelled)), Some(&r)),
        Err(QueueError::Receipt(Status::Cancelled))
    ));
    let (settled, change) = owner
        .apply(&a, &ev(1, Kind::Settle(Settle::Cancelled)), None)
        .unwrap();
    assert_eq!(
        (settled.status, change.reason),
        (Status::Cancelled, "cancelled")
    );
    assert!(matches!(
        owner.heartbeat(&a, 1, 60),
        Err(QueueError::NotLive(_))
    ));
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Cancelled));
    let shown = s.task(&id).unwrap().unwrap();
    assert_eq!(shown["status"], "cancelled");
}

#[test]
fn a_marked_attempt_that_goes_back_to_the_queue_is_cancelled_there() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = submitter(&pg);
    // leased, never started: the expiry that would queue it again cancels it
    let a = owner.claim(&claude_slot(), 60).unwrap().unwrap().attempt.id;
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Leased));
    overdue(&pg, &a);
    let changes = owner.reconcile().unwrap();
    assert_eq!(
        changes.iter().map(|c| (c.to, c.reason)).collect::<Vec<_>>(),
        [(Status::Cancelled, "cancelled")]
    );
    assert_eq!(status(&pg, &a), ("cancelled".to_owned(), 2));
    // a prepare that failed settles to queued: cancelled instead
    let b = submit(&mut owner, &task("t-2", 2));
    owner.claim(&slot("s0"), 60).unwrap().unwrap();
    owner.apply(&b, &ev(1, Kind::Start), None).unwrap();
    pg.sql()
        .execute(
            "UPDATE attempts SET cancel_requested = true, fence = lease_epoch WHERE id = $1",
            &[&b],
        )
        .unwrap();
    owner.apply(&b, &ev(1, Kind::Checkpoint), None).unwrap();
    let (settled, _) = owner
        .apply(&b, &ev(1, Kind::Settle(Settle::Queued)), None)
        .unwrap();
    assert_eq!(settled.status, Status::Cancelled);
}

#[test]
fn a_cancel_asked_of_a_dead_runner_still_expires_to_review() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = submitter(&pg);
    let a = owner.claim(&claude_slot(), 60).unwrap().unwrap().attempt.id;
    owner.apply(&a, &ev(1, Kind::Start), None).unwrap();
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Running));
    overdue(&pg, &a);
    assert!(matches!(
        owner.heartbeat(&a, 1, 60),
        Err(QueueError::NotLive(_))
    ));
    assert_eq!(owner.reconcile().unwrap().len(), 1);
    assert_eq!(status(&pg, &a), ("needs_review".to_owned(), 2));
    // the submitter settles the review itself
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Cancelled));
    assert_eq!(status(&pg, &a).0, "cancelled");
}

#[test]
fn a_paused_task_wakes_without_spending_an_attempt() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let a = submit(&mut s, &task("t-1", 1));
    s.claim(&slot("s0"), 60).unwrap().unwrap();
    for kind in [
        Kind::Start,
        Kind::Checkpoint,
        Kind::Settle(Settle::Waiting),
        Kind::Wake,
    ] {
        s.apply(&a, &ev(1, kind), None).unwrap();
    }
    assert_eq!(status(&pg, &a), ("queued".to_owned(), 1));
    let again = s.claim(&slot("s1"), 60).unwrap().unwrap();
    assert_eq!((again.attempt.lease_epoch, again.attempt.tries), (2, 1));
}

#[test]
fn a_claim_takes_only_what_fits_its_slot() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    let mut claude = task("t-claude", 1);
    claude.command.agent = Agent::Claude;
    let old = submit(&mut s, &claude);
    let new = submit(&mut s, &task("t-none", 1));
    // the oldest queued task needs claude, which s0 does not run: s0 gets the newer one
    let none_slot = slot("s0");
    assert_eq!(s.claim(&none_slot, 60).unwrap().unwrap().attempt.id, new);
    assert!(s.live_on(&none_slot).unwrap().is_some_and(|a| a.id == new));
    let mut claude_slot = slot("s1");
    claude_slot.agents = BTreeSet::from([Agent::Claude]);
    assert_eq!(s.live_on(&claude_slot).unwrap(), None);
    assert_eq!(s.claim(&claude_slot, 60).unwrap().unwrap().attempt.id, old);
    let mut idle = slot("s2");
    idle.agents = BTreeSet::from([Agent::Claude]);
    assert!(s.claim(&idle, 60).unwrap().is_none());
}

fn cli(pg: &Pg, args: &[&str], stdin: &str) -> (Option<i32>, String) {
    use std::io::Write as _;
    let mut child = Command::new(env!("CARGO_BIN_EXE_exec-pool-queue"))
        .args(args)
        .env("EXEC_POOL_DB", pg.conninfo())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    (out.status.code(), String::from_utf8(out.stdout).unwrap())
}

#[test]
fn the_submitter_cli_cancels_its_task_and_wait_returns_on_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let theirs = submit(&mut owner, &task("t-1", 1));
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_exec-pool"))
            .args(args)
            // no repository list: these submit example.org, which the pool host's list would refuse
            .env("EXEC_POOL_REPOS", "/nonexistent")
            .env(
                "EXEC_POOL_DB",
                pg.conninfo()
                    .replace("user=exec_pool ", "user=exec_pool_submit "),
            )
            .output()
            .unwrap()
    };
    let submitter = |args: &[&str]| {
        let out = run(args);
        (out.status.code(), String::from_utf8(out.stdout).unwrap())
    };
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
    let refused = run(&[
        "submit",
        "--agent",
        "pi",
        "--repo",
        "https://example.org/r.git",
        "--rev",
        "abc",
        "--workdir",
        "w",
        "--prompt",
        "p",
    ]);
    let stderr = String::from_utf8(refused.stderr).unwrap();
    assert_eq!(refused.status.code(), Some(1), "{stderr}");
    assert!(
        stderr.contains("offers agent pi") && stderr.contains("offered: claude"),
        "{stderr}"
    );
    let (code, id) = submitter(&[
        "submit",
        "--agent",
        "claude",
        "--repo",
        "https://example.org/r.git",
        "--rev",
        "abc",
        "--workdir",
        "w",
        "--prompt",
        "p",
    ]);
    assert_eq!(code, Some(0));
    let id = id.trim();
    let (code, out) = submitter(&["cancel", id]);
    assert_eq!(code, Some(0));
    let shown: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(
        shown,
        json!({ "attempt": format!("{id}.a"), "status": "cancelled" })
    );
    let (code, out) = submitter(&["wait", id, "--timeout", "5"]);
    assert_eq!(code, Some(0), "wait returns on a cancelled task");
    assert!(out.contains(r#""status":"cancelled""#), "{out}");
    assert_eq!(submitter(&["cancel", &theirs]).0, Some(1), "not its own");
    assert_eq!(submitter(&["cancel"]).0, Some(2));
}

#[test]
fn the_cli_logs_one_line_per_change_and_exits_75_without_a_database() {
    let mut pg = Pg::new();
    assert_eq!(cli(&pg, &["migrate"], "").0, Some(0));
    let spec = serde_json::to_string(&task("t-1", 1)).unwrap();
    let (code, out) = cli(&pg, &["submit", "--granted", "read_only"], &spec);
    assert_eq!(code, Some(0));
    let lines: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["msg"], "state_change");
    assert_eq!(lines[0]["change"]["to"], "queued");
    assert_eq!(lines[1]["result"]["attempt"], "t-1.a");
    // a capability the submitter was not granted is refused
    assert_eq!(cli(&pg, &["submit", "--granted", ""], &spec).0, Some(1));
    let (code, out) = cli(
        &pg,
        &["claim", "--lease-secs", "60"],
        &serde_json::to_string(&slot("s0")).unwrap(),
    );
    assert_eq!(code, Some(0));
    assert!(out.lines().count() == 2 && out.contains("\"to\":\"leased\""));
    assert_eq!(
        cli(&pg, &["start", "--attempt", "t-1.a", "--epoch", "0"], "").0,
        Some(1),
        "stale epoch"
    );
    assert_eq!(cli(&pg, &["start", "--attempt", "t-1.a"], "").0, Some(2));
    assert_eq!(
        cli(
            &pg,
            &[
                "start",
                "--attempt",
                "t-1.a",
                "--epoch",
                "1",
                "--epoch",
                "1"
            ],
            ""
        )
        .0,
        Some(2),
        "a repeated flag"
    );
    assert_eq!(
        cli(&pg, &["submit", "--granted", "read_only"], "").0,
        Some(1),
        "empty stdin"
    );
    let (code, out) = cli(&pg, &["start", "--attempt", "t-1.a", "--epoch", "1"], "");
    assert_eq!(code, Some(0));
    let lines: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(
        (&lines[0]["change"]["to"], &lines[1]["result"]["status"]),
        (&json!("running"), &json!("running"))
    );
    let (code, out) = cli(&pg, &["live"], &serde_json::to_string(&slot("s0")).unwrap());
    assert_eq!(code, Some(0));
    assert!(out.contains("\"id\":\"t-1.a\""), "{out}");

    // a schema-less database is a failure too, rendered absent rather than empty
    let mut c = pg.sql();
    c.batch_execute("ALTER TABLE attempts RENAME TO attempts_moved")
        .unwrap();
    let (code, out) = cli(&pg, &["metrics"], "");
    assert_eq!((code, out.as_str()), (Some(1), METRICS_UNAVAILABLE));
    c.batch_execute("ALTER TABLE attempts_moved RENAME TO attempts")
        .unwrap();

    pg.stop();
    let (code, out) = cli(&pg, &["metrics"], "");
    assert_eq!((code, out.as_str()), (Some(75), METRICS_UNAVAILABLE));
    assert_eq!(cli(&pg, &["reconcile"], "").0, Some(75));

    // a failure before any query (here no EXEC_POOL_DB) still reads absent, never an empty textfile
    let out = Command::new(env!("CARGO_BIN_EXE_exec-pool-queue"))
        .arg("metrics")
        .env_remove("EXEC_POOL_DB")
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(
        (
            out.status.code(),
            String::from_utf8(out.stdout).unwrap().as_str()
        ),
        (Some(2), METRICS_UNAVAILABLE)
    );
}

/// A store as `exec_pool_submit`, and the session it started through `start_session`.
fn session(pg: &Pg) -> (Store, String) {
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_submit ");
    let mut s = Store::open(&conninfo).unwrap();
    let task: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    assert!(
        matches!(s.start_session(&task, 0), Err(QueueError::Db { code, .. }) if code == "22023"),
        "0008's check: no slot seen offers claude"
    );
    assert!(pg.store().claim(&claude_slot(), 60).unwrap().is_none());
    let (id, duplicate) = s.start_session(&task, 0).unwrap();
    assert!(!duplicate);
    (s, id)
}

/// Claims the next turn on the claude slot and starts it: its attempt, epoch and turn.
fn started(owner: &mut Store) -> (String, u64, Turn) {
    let claim = owner.claim(&claude_slot(), 60).unwrap().unwrap();
    let (a, epoch) = (claim.attempt.id, claim.attempt.lease_epoch);
    owner.apply(&a, &ev(epoch, Kind::Start), None).unwrap();
    (
        a,
        epoch,
        claim.turn.expect("a session's claim hands over its turn"),
    )
}

fn park(reason: ParkReason, upto: i64) -> Park {
    Park {
        reason,
        checkpoint: Some(CheckpointRef {
            schema_version: SchemaVersion::CURRENT,
            uri: "checkpoint://s/1".to_owned(),
            digest: "sha256-x".to_owned(),
            generation: 0,
            legacy_hosts: exec_pool::Ignored,
        }),
        result: TaskResult::new(Some(Outcome::Succeeded), Some(0), "the turn's answer"),
        upto,
        undelivered: false,
        wake: None,
        transcript: None,
        arm: None,
        memory_killed: Vec::new(),
    }
}

fn moves(changes: &[exec_pool::queue::Change]) -> Vec<(Status, &'static str)> {
    changes.iter().map(|c| (c.to, c.reason)).collect()
}

#[test]
fn a_message_sent_while_a_turn_runs_is_delivered_after_its_park() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, first) = started(&mut owner);
    assert!(first.first);
    assert_eq!((first.input.as_str(), first.upto), (ARGV_MARKER, 0));
    assert_eq!(
        s.send(&id, "and then this").unwrap(),
        (a.clone(), Status::Running)
    );
    let (parked, changes) = owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, first.upto))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "turn_end"), (Status::Queued, "wake")],
        "the unread message queues the next turn in the same transaction"
    );
    assert_eq!(
        (parked.status, parked.tries, parked.placement),
        (Status::Queued, 0, None)
    );
    let row = pg
        .sql()
        .query_one("SELECT checkpoint FROM attempts WHERE id = $1", &[&a])
        .unwrap();
    let checkpoint: serde_json::Value = row.get(0);
    assert_eq!(checkpoint["generation"], epoch);
    assert_eq!(
        s.result(&id).unwrap().unwrap()["result"]["output"],
        "the turn's answer"
    );

    let (a, epoch, second) = started(&mut owner);
    assert!(!second.first);
    assert_eq!(second.session_uuid, first.session_uuid);
    assert_eq!(second.input, "and then this");
    assert!(second.upto > 0);
    let (parked, changes) = owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, second.upto))
        .unwrap();
    assert_eq!(moves(&changes), [(Status::Waiting, "turn_end")]);
    assert_eq!((parked.status, parked.tries), (Status::Waiting, 0));
    let shown = s.task(&id).unwrap().unwrap();
    assert_eq!(
        (&shown["session"], &shown["parked"]),
        (&json!(true), &json!("turn_end"))
    );
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics
            .lines()
            .any(|l| l == "exec_pool_waiting{host=\"msi-ms7758\",reason=\"turn_end\"} 1"),
        "{metrics}"
    );
    assert!(
        metrics
            .lines()
            .any(|l| l == "exec_pool_waiting{host=\"msi-ms7758\",reason=\"preempted\"} 0")
    );
    assert!(
        metrics.contains("reason=\"turn_end\"} 2"),
        "both parks count in exec_pool_transitions_total"
    );
}

#[test]
fn only_a_reply_parked_past_the_window_with_an_empty_inbox_counts_as_unread() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, old) = session(&pg);
    let mut parked_ago = |s: &mut Store, key: Option<&str>, minutes: i32| {
        let id = key.map_or_else(
            || old.clone(),
            |k| {
                let mut task: TaskSpec = serde_json::from_value(agent_task()).unwrap();
                k.clone_into(&mut task.idempotency_key);
                s.start_session(&task, 0).unwrap().0
            },
        );
        let (a, epoch, turn) = started(&mut owner);
        owner
            .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
            .unwrap();
        pg.sql()
            .execute(
                "UPDATE events SET at = now() - make_interval(mins => $2) \
                 WHERE attempt_id = $1 AND to_status = 'waiting'",
                &[&a, &minutes],
            )
            .unwrap();
        id
    };
    parked_ago(&mut s, None, 20);
    let fresh = parked_ago(&mut s, Some("cli:fresh"), 5);
    let sent = parked_ago(&mut s, Some("cli:sent"), 30);
    let timed = parked_ago(&mut s, Some("cli:timed"), 50);
    s.send_timer(&timed, "later", "2999-01-01T00:00:00Z").unwrap();
    let closed = parked_ago(&mut s, Some("cli:closed"), 40);
    s.cancel(&closed).unwrap();
    s.send(&sent, "and then this").unwrap();
    let oldest = |m: &str, why: &str| -> i64 {
        let head =
            format!("exec_pool_waiting_oldest_seconds{{host=\"msi-ms7758\",reason=\"{why}\"}} ");
        m.lines()
            .find_map(|l| l.strip_prefix(&head))
            .unwrap_or_else(|| panic!("{m}"))
            .parse()
            .unwrap()
    };
    let metrics = owner.metrics().unwrap();
    let age = oldest(&metrics, "turn_end");
    assert!(
        (1200..1260).contains(&age),
        "the 20 minute one, not the re-queued, timed or closed ones: {age}"
    );
    assert_eq!(oldest(&metrics, "preempted"), 0);
    for id in [&old, &fresh, &sent, &timed, &closed] {
        assert!(!metrics.contains(id.as_str()), "no id in the metrics: {id}");
    }
    s.cancel(&old).unwrap();
    let age = oldest(&owner.metrics().unwrap(), "turn_end");
    assert!((300..360).contains(&age), "the 5 minute one: {age}");
    s.cancel(&fresh).unwrap();
    assert_eq!(oldest(&owner.metrics().unwrap(), "turn_end"), 0);
}

#[test]
fn a_message_sent_while_a_turn_runs_reaches_its_pane_and_is_read_at_its_park() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, first) = started(&mut owner);
    let mut runner = runner(&pg);
    assert_eq!(
        runner.during_turn(&id, first.upto).unwrap(),
        (vec![], false)
    );
    s.send(&id, "review: fix the test").unwrap();
    s.send(&id, "and rebase").unwrap();
    let (mail, busy) = runner.during_turn(&id, first.upto).unwrap();
    assert_eq!(
        mail.iter().map(|(_, b)| b.as_str()).collect::<Vec<_>>(),
        ["review: fix the test", "and rebase"]
    );
    assert!(!busy, "nothing waits for a slot");
    let upto = mail.iter().map(|(i, _)| *i).max().unwrap();
    assert_eq!(runner.during_turn(&id, upto).unwrap().0, vec![]);
    // queued work and the one slot busy: an idle agent's grace is the short one
    submit(&mut owner, &task("queued-behind", 1));
    assert!(runner.during_turn(&id, upto).unwrap().1);
    let (_, changes) = owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, upto))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "turn_end")],
        "what the pane was given is read: no turn for it again"
    );
}

#[test]
fn a_send_queues_a_waiting_session_and_two_sends_arrive_once_in_order() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting");
    assert!(
        owner.claim(&claude_slot(), 60).unwrap().is_none(),
        "waiting is not claimed"
    );
    assert_eq!(s.send(&id, "one").unwrap(), (a.clone(), Status::Queued));
    assert_eq!(
        s.send(&a, "two").unwrap(),
        (a.clone(), Status::Queued),
        "by its attempt id too"
    );
    let (_, epoch, turn) = started(&mut owner);
    assert_eq!(turn.input, "one\n\ntwo");
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(
        status(&pg, &a).0,
        "waiting",
        "both were read: nothing wakes it"
    );
    s.send(&id, "three").unwrap();
    let (_, _, turn) = started(&mut owner);
    assert_eq!(turn.input, "three");
}

#[test]
fn a_session_is_claimed_by_any_host_parked_or_not() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut acer = claude_slot();
    acer.host = "acer-swift".to_owned();
    let (a, epoch, first) = started(&mut owner);
    assert_eq!(first.checkpoint, None);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    s.send(&id, "one").unwrap();
    let claim = owner
        .claim(&acer, 60)
        .unwrap()
        .expect("its work is on its remote: any host");
    let turn = claim.turn.unwrap();
    assert_eq!(turn.checkpoint.map(|c| c.generation), Some(epoch));
    // a turn whose lease was lost while it ran, before its park: nothing of it is on acer either
    let epoch = claim.attempt.lease_epoch;
    owner.apply(&a, &ev(epoch, Kind::Start), None).unwrap();
    overdue(&pg, &a);
    assert_eq!(owner.reconcile().unwrap().len(), 1);
    assert_eq!(status(&pg, &a).0, "needs_review");
    s.send(&id, "go on").unwrap();
    let mut asus = claude_slot();
    asus.host = "asus-b460m".to_owned();
    assert!(owner.claim(&asus, 60).unwrap().is_some());
}

#[test]
fn a_checkpoint_the_runner_cannot_read_is_skipped_not_fatal() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let first = submit(&mut owner, &task("t-1", 1));
    let second = submit(&mut owner, &task("t-2", 1));
    pg.sql()
        .execute(
            "UPDATE attempts SET checkpoint = '{\"schema_version\": 2}', fence = lease_epoch WHERE id = $1",
            &[&first],
        )
        .unwrap();
    let claim = owner.claim(&slot("s0"), 60).unwrap().unwrap();
    assert_eq!(claim.attempt.id, second);
}

#[test]
fn a_first_turn_is_claimed_on_any_host() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    let mut acer = claude_slot();
    acer.host = "acer-swift".to_owned();
    let claim = owner.claim(&acer, 60).unwrap().unwrap();
    assert!(claim.turn.unwrap().first);
}

#[test]
fn a_turn_that_never_parks_is_handed_its_messages_again() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    s.send(&id, "one").unwrap();
    // the turn that was handed it dies before its park: its lease expires to review, the row still unread
    let (_, _, turn) = started(&mut owner);
    assert_eq!(turn.input, "one");
    overdue(&pg, &a);
    assert_eq!(owner.reconcile().unwrap().len(), 1);
    s.send(&id, "two").unwrap();
    let (_, _, turn) = started(&mut owner);
    assert_eq!(turn.input, "one\n\ntwo");
}

#[test]
fn a_turn_rides_through_the_queue_restarting_under_its_lease() {
    // a deploy of the queue's host restarts PostgreSQL under another host's running turn
    let mut pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    pg.stop();
    assert!(matches!(
        owner.heartbeat(&a, epoch, 60),
        Err(QueueError::Unavailable(_))
    ));
    assert!(matches!(
        owner.park(&a, epoch, &park(ParkReason::HostDraining, 0)),
        Err(QueueError::Unavailable(_))
    ));
    pg.start();
    // the lease taken before the outage still holds: the same store renews it and parks the turn once
    assert!(!owner.heartbeat(&a, epoch, 60).unwrap());
    let (_, changes) = owner
        .park(&a, epoch, &park(ParkReason::HostDraining, 0))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "host_draining"), (Status::Queued, "wake")]
    );
}

#[test]
fn every_migration_since_sessions_keeps_the_floor_an_older_runner_serves() {
    // a remote runner never migrates: a deploy of the queue's host applies a migration under msi's runner, which runs
    // the binary its own host was last deployed with, so a migration raising the floor breaks it until that deploy
    const RUNNER_FLOOR: i32 = 9;
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    let mut seen = 0;
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_str().unwrap().to_owned();
        let Some(version) = name
            .strip_suffix(".up.sql")
            .and_then(|n| n.split('_').next())
            .and_then(|v| v.parse::<i32>().ok())
            .filter(|v| *v >= RUNNER_FLOOR)
        else {
            continue;
        };
        let sql = std::fs::read_to_string(&path).unwrap();
        let recorded =
            format!("INSERT INTO schema_migrations (version, floor) VALUES ({version}, ");
        let floor: i32 = sql
            .split(&recorded)
            .nth(1)
            .and_then(|rest| rest.split(')').next())
            .and_then(|f| f.trim().parse().ok())
            .unwrap_or_else(|| panic!("{name} records no floor"));
        assert!(
            floor <= RUNNER_FLOOR,
            "{name} raises the floor to {floor}: deploy every runner host first, then raise RUNNER_FLOOR here"
        );
        seen += 1;
    }
    assert!(seen >= 8, "{seen} migrations read");
}

#[test]
fn a_turn_stopped_for_a_poweroff_continues_and_is_told_to_check_its_last_action() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    s.send(&id, "and then this").unwrap();
    let (_, changes) = owner
        .park(&a, epoch, &park(ParkReason::HostDraining, 0))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "host_draining"), (Status::Queued, "wake")]
    );
    let (a, epoch, turn) = started(&mut owner);
    assert!(
        turn.input.starts_with(
            "You were paused mid-turn by the pool (its host was powering off or being deployed)."
        ),
        "{}",
        turn.input
    );
    assert!(turn.input.ends_with("\n\nand then this"), "{}", turn.input);
    // its park reads both, the continue and the older message under it
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting");
    s.send(&id, "later").unwrap();
    let (_, _, turn) = started(&mut owner);
    assert_eq!(turn.input, "later", "after a turn that ended, no note");
}

/// The runner's store: a park as the runner role reads only what it is granted.
fn runner(pg: &Pg) -> Store {
    Store::open(
        &pg.conninfo()
            .replace("user=exec_pool ", "user=exec_pool_runner "),
    )
    .unwrap()
}

/// Runs the next turn to its time limit: its input and the changes its park made.
fn time_out(runner: &mut Store) -> (String, Vec<(Status, &'static str)>) {
    let (a, epoch, turn) = started(runner);
    let (_, changes) = runner
        .park(&a, epoch, &park(ParkReason::TurnTimeout, turn.upto))
        .unwrap();
    (turn.input, moves(&changes))
}

const CONTINUED: [(Status, &str); 2] =
    [(Status::Waiting, "turn_timeout"), (Status::Queued, "wake")];

#[test]
fn a_timed_out_turn_continues_and_the_third_in_a_row_waits() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    let (first, changes) = time_out(&mut runner);
    assert_eq!(first, ARGV_MARKER);
    assert_eq!(changes, CONTINUED, "its continue row wakes it");
    let (second, changes) = time_out(&mut runner);
    assert_eq!(
        second,
        "Your last turn hit the time limit. Check your last action, then continue."
    );
    assert_eq!(changes, CONTINUED);
    let (_, changes) = time_out(&mut runner);
    assert_eq!(
        changes,
        [(Status::Waiting, "turn_timeout")],
        "no continue row: a stuck loop stops"
    );
    let shown = s.task(&id).unwrap().unwrap();
    assert_eq!(
        (&shown["status"], &shown["parked"]),
        (&json!("waiting"), &json!("turn_timeout"))
    );
    assert!(runner.claim(&claude_slot(), 60).unwrap().is_none());
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics
            .lines()
            .any(|l| l == "exec_pool_waiting{host=\"msi-ms7758\",reason=\"turn_timeout\"} 1"),
        "{metrics}"
    );
    assert!(
        metrics.contains("reason=\"turn_timeout\"} 3"),
        "every timed-out park counts in exec_pool_transitions_total"
    );
    assert!(
        metrics
            .lines()
            .any(|l| l
                == "exec_pool_sessions_stalled{host=\"msi-ms7758\",reason=\"turn_timeout\"} 1"),
        "{metrics}"
    );
}

#[test]
fn a_turn_error_continues_after_a_growing_delay_and_past_the_bound_counts_as_stalled() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    let stalled = |m: &str, n: u8| {
        m.lines().any(|l| {
            l == format!(
                "exec_pool_sessions_stalled{{host=\"msi-ms7758\",reason=\"turn_error\"}} {n}"
            )
        })
    };
    for (n, secs) in exec_pool::queue::ERROR_BACKOFF_SECS.iter().enumerate() {
        let (a, epoch, turn) = started(&mut runner);
        if n > 0 {
            assert!(
                turn.input.starts_with("Your last turn ended in an error"),
                "a new turn told what happened, not a replay: {}",
                turn.input
            );
        }
        let (_, changes) = runner
            .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
            .unwrap();
        assert_eq!(
            moves(&changes),
            [(Status::Waiting, "turn_error")],
            "error {n}"
        );
        let due: i64 = pg
            .sql()
            .query_one(
                "SELECT extract(epoch FROM due_at - now())::int8 FROM inbox \
                 WHERE kind = 'continue' AND consumed_epoch IS NULL",
                &[],
            )
            .unwrap()
            .get(0);
        assert!(
            (i64::from(*secs) - 60..=i64::from(*secs)).contains(&due),
            "error {n}: continue due in {due} s, not {secs}"
        );
        assert!(
            runner.claim(&claude_slot(), 60).unwrap().is_none(),
            "not before it is due"
        );
        assert!(owner.reconcile().unwrap().is_empty());
        assert!(
            stalled(&owner.metrics().unwrap(), 0),
            "a continue is still to come"
        );
        pg.sql()
            .execute(
                "UPDATE inbox SET due_at = now() - interval '1 second' WHERE consumed_epoch IS NULL",
                &[],
            )
            .unwrap();
        assert_eq!(
            moves(&owner.reconcile().unwrap()),
            [(Status::Queued, "wake")]
        );
    }
    let (a, epoch, turn) = started(&mut runner);
    runner
        .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
        .unwrap();
    let unread: i64 = pg
        .sql()
        .query_one(
            "SELECT count(*) FROM inbox WHERE consumed_epoch IS NULL",
            &[],
        )
        .unwrap()
        .get(0);
    assert_eq!(unread, 0, "the bound is spent: no continue");
    let metrics = owner.metrics().unwrap();
    assert!(stalled(&metrics, 1), "{metrics}");
    assert!(
        metrics
            .lines()
            .any(|l| l
                == "exec_pool_sessions_stalled{host=\"msi-ms7758\",reason=\"turn_timeout\"} 0"),
        "{metrics}"
    );
    s.send(&id, "go on").unwrap();
    assert!(stalled(&owner.metrics().unwrap(), 0), "a message moves it");
    let (a, epoch, turn) = started(&mut runner);
    assert_eq!(turn.input, "go on");
    let (_, changes) = runner
        .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
        .unwrap();
    assert_eq!(moves(&changes), [(Status::Waiting, "turn_error")]);
    let pending: i64 = pg
        .sql()
        .query_one(
            "SELECT count(*) FROM inbox WHERE kind = 'continue' AND consumed_epoch IS NULL",
            &[],
        )
        .unwrap()
        .get(0);
    assert_eq!(pending, 1, "the message's turn is the first of a new run");
}

/// Parks the next turn as a `turn_error`: its input and the changes its park made.
fn error_out(runner: &mut Store) -> (String, Vec<(Status, &'static str)>) {
    let (a, epoch, turn) = started(runner);
    let (_, changes) = runner
        .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
        .unwrap();
    (turn.input, moves(&changes))
}

#[test]
fn a_memory_kill_continues_as_an_error_does_and_tells_the_agent_what_was_killed() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    let killed = |runner: &mut Store| {
        let (a, epoch, turn) = started(runner);
        let mut p = park(ParkReason::TurnMemoryKill, turn.upto);
        p.memory_killed = vec!["nix".to_owned(), "bad name;".to_owned()];
        moves(&runner.park(&a, epoch, &p).unwrap().1)
    };
    assert_eq!(killed(&mut runner), [(Status::Waiting, "turn_memory_kill")]);
    assert_eq!(all_due(&pg, &mut owner), [(Status::Queued, "wake")]);
    let (a, epoch, turn) = started(&mut runner);
    assert!(
        turn.input
            .starts_with("Your last turn ended in an error after the kernel's OOM killer")
            && turn.input.contains("Killed: nix.")
            && !turn.input.contains("bad name"),
        "{}",
        turn.input
    );
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    // as a remote runner's park into a queue host still at 22: the claim's text names nothing
    pg.sql()
        .batch_execute("DROP FUNCTION continue_after(text, int8, text)")
        .unwrap();
    s.send(&id, "go on").unwrap();
    assert_eq!(killed(&mut runner), [(Status::Waiting, "turn_memory_kill")]);
    assert_eq!(all_due(&pg, &mut owner), [(Status::Queued, "wake")]);
    let (_, _, turn) = started(&mut runner);
    assert!(
        turn.input
            .starts_with("Your last turn ended in an error after the kernel's OOM killer")
            && !turn.input.contains("Killed:"),
        "{}",
        turn.input
    );
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics.lines().any(|l| l
            == "exec_pool_session_turns_total{host=\"msi-ms7758\",reason=\"turn_memory_kill\"} 2"),
        "{metrics}"
    );
}

/// Makes every unread inbox row due now and runs a reconcile: the changes it made.
fn all_due(pg: &Pg, owner: &mut Store) -> Vec<(Status, &'static str)> {
    pg.sql()
        .execute(
            "UPDATE inbox SET due_at = now() - interval '1 second' WHERE consumed_epoch IS NULL",
            &[],
        )
        .unwrap();
    moves(&owner.reconcile().unwrap())
}

#[test]
fn a_backoff_continue_overtaken_by_a_message_never_wakes_the_session_later() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    assert_eq!(error_out(&mut runner).1, [(Status::Waiting, "turn_error")]);
    s.send(&id, "here is what went wrong").unwrap();
    let (a, epoch, turn) = started(&mut runner);
    assert_eq!(turn.input, "here is what went wrong");
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(
        all_due(&pg, &mut owner),
        [],
        "the error's continue went with the turn the message started"
    );
    assert_eq!(status(&pg, &a).0, "waiting");
}

#[test]
fn errors_and_timeouts_in_turn_share_one_bound() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    let mut runner = runner(&pg);
    assert_eq!(error_out(&mut runner).1, [(Status::Waiting, "turn_error")]);
    assert_eq!(all_due(&pg, &mut owner), [(Status::Queued, "wake")]);
    let (_, changes) = time_out(&mut runner);
    assert_eq!(changes, CONTINUED, "the second of the run");
    assert_eq!(error_out(&mut runner).1, [(Status::Waiting, "turn_error")]);
    assert_eq!(all_due(&pg, &mut owner), [(Status::Queued, "wake")]);
    let (_, changes) = time_out(&mut runner);
    assert_eq!(
        changes,
        [(Status::Waiting, "turn_timeout")],
        "the fourth: no continue"
    );
    assert_eq!(all_due(&pg, &mut owner), []);
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics
            .lines()
            .any(|l| l
                == "exec_pool_sessions_stalled{host=\"msi-ms7758\",reason=\"turn_timeout\"} 1"),
        "{metrics}"
    );
}

#[test]
fn a_message_starts_the_count_of_timeouts_in_a_row_again() {
    let pg = Pg::new();
    let _owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    for _ in 0..2 {
        assert_eq!(time_out(&mut runner).1, CONTINUED);
    }
    assert_eq!(time_out(&mut runner).1, [(Status::Waiting, "turn_timeout")]);
    s.send(&id, "try it another way").unwrap();
    let (input, changes) = time_out(&mut runner);
    assert_eq!(input, "try it another way");
    assert_eq!(
        changes, CONTINUED,
        "the message's turn is the first of a new run"
    );
    assert_eq!(time_out(&mut runner).1, CONTINUED);
    assert_eq!(time_out(&mut runner).1, [(Status::Waiting, "turn_timeout")]);
}

#[test]
fn a_one_shot_run_drained_while_preparing_runs_again_one_drained_mid_run_goes_to_review() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let tries = |a: &str| -> i32 {
        pg.sql()
            .query_one("SELECT tries FROM attempts WHERE id = $1", &[&a])
            .unwrap()
            .get(0)
    };
    let last_reason = |a: &str| -> String {
        pg.sql()
            .query_one(
                "SELECT reason FROM events WHERE attempt_id = $1 ORDER BY id DESC LIMIT 1",
                &[&a],
            )
            .unwrap()
            .get(0)
    };
    // drained before its agent started: back to the queue with its one try
    let a = submit(&mut owner, &task("t-1", 1));
    let epoch = owner
        .claim(&slot("s0"), 60)
        .unwrap()
        .unwrap()
        .attempt
        .lease_epoch;
    for kind in [Kind::Start, Kind::Checkpoint, Kind::Settle(Settle::Drained)] {
        owner.apply(&a, &ev(epoch, kind), None).unwrap();
    }
    assert_eq!((status(&pg, &a).0.as_str(), tries(&a)), ("queued", 0));
    assert_eq!(last_reason(&a), "host_draining");
    let epoch = owner
        .claim(&slot("s1"), 60)
        .unwrap()
        .unwrap()
        .attempt
        .lease_epoch;
    // drained after it: what it pushed is unknown, so it goes to review with its receipt, never queued again
    for kind in [Kind::Start, Kind::Checkpoint] {
        owner.apply(&a, &ev(epoch, kind), None).unwrap();
    }
    let interrupted = ev(epoch, Kind::Settle(Settle::Interrupted));
    assert!(
        owner.apply(&a, &interrupted, None).is_err(),
        "a review takes a receipt"
    );
    owner
        .apply(
            &a,
            &interrupted,
            Some(&receipt(&a, "t-1", epoch, "needs_review")),
        )
        .unwrap();
    assert_eq!(status(&pg, &a).0, "needs_review");
    assert_eq!(last_reason(&a), "host_draining");
    assert!(owner.claim(&slot("s2"), 60).unwrap().is_none());
}

#[test]
fn a_preempted_turn_continues_at_once() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let (_, changes) = owner
        .park(&a, epoch, &park(ParkReason::Preempted, 0))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "preempted"), (Status::Queued, "wake")]
    );
    let (a, epoch, turn) = started(&mut owner);
    assert!(
        turn.input.contains("Continue where you left off"),
        "{}",
        turn.input
    );
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting");
}

#[test]
fn a_park_at_a_stale_epoch_or_of_a_one_shot_task_is_refused() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    assert!(matches!(
        owner.park(&a, epoch - 1, &park(ParkReason::TurnEnd, 0)),
        Err(QueueError::Contract(Error::StaleEpoch { .. }))
    ));
    overdue(&pg, &a);
    assert!(matches!(
        owner.park(&a, epoch, &park(ParkReason::TurnEnd, 0)),
        Err(QueueError::NotLive(_))
    ));
    owner.reconcile().unwrap();
    assert!(matches!(
        owner.park(&a, epoch, &park(ParkReason::TurnEnd, 0)),
        Err(QueueError::Contract(Error::StaleEpoch { .. }))
    ));
    assert_eq!(
        status(&pg, &a),
        ("needs_review".to_owned(), i64::try_from(epoch).unwrap() + 1)
    );

    let b = submit(&mut owner, &task("t-1", 2));
    let claim = owner.claim(&slot("s0"), 60).unwrap().unwrap();
    assert_eq!(claim.turn, None, "a one-shot task has no turn");
    owner.apply(&b, &ev(1, Kind::Start), None).unwrap();
    assert!(matches!(
        owner.park(&b, 1, &park(ParkReason::TurnEnd, 0)),
        Err(QueueError::NotSession(_))
    ));
    assert_eq!(status(&pg, &b), ("running".to_owned(), 1));
}

#[test]
fn needs_review_is_left_only_by_a_send_or_a_resolve() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, _, _) = started(&mut owner);
    overdue(&pg, &a);
    owner.reconcile().unwrap();
    let (_, epoch) = status(&pg, &a);
    let epoch = u64::try_from(epoch).unwrap();
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
    assert!(owner.apply(&a, &ev(epoch, Kind::Wake), None).is_err());
    assert!(
        owner
            .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
            .is_err()
    );
    assert_eq!(status(&pg, &a).0, "needs_review");
    // the owner's message resumes it with the try given back, though max_attempts is 1
    assert_eq!(s.send(&id, "go on").unwrap(), (a.clone(), Status::Queued));
    let (a, epoch, turn) = started(&mut owner);
    assert!(!turn.first, "its first turn had started");
    assert_eq!(turn.input, "go on");
    overdue(&pg, &a);
    owner.reconcile().unwrap();
    let (resumed, change) = owner
        .apply(&a, &ev(epoch + 1, Kind::Resolve(Resolution::Resume)), None)
        .unwrap();
    assert_eq!(
        (resumed.status, resumed.tries, change.reason),
        (Status::Queued, 0, "operator")
    );
}

#[test]
fn a_one_shot_or_settled_task_takes_no_message() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = submitter(&pg);
    assert!(matches!(
        s.send(&id, "hello"),
        Err(QueueError::Db { code, .. }) if code == "22023"
    ));
    let theirs = submit(&mut owner, &task("t-1", 1));
    assert!(matches!(
        s.send(&theirs, "hello"),
        Err(QueueError::NotFound(_))
    ));
    let mut codex: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    codex.command.agent = Agent::Codex;
    codex.idempotency_key = "cli:codex".to_owned();
    assert!(
        s.start_session(&codex, 0).is_err(),
        "a session is claude only"
    );
    let one_shot: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    assert!(
        matches!(s.start_session(&one_shot, 0), Err(QueueError::Db { code, .. }) if code == "23505"),
        "its key names the one-shot task"
    );
    let mut later: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    later.idempotency_key = "cli:2".to_owned();
    let (sid, _) = s.start_session(&later, 0).unwrap();
    assert_eq!(s.start_session(&later, 0).unwrap(), (sid.clone(), true));
    s.cancel(&sid).unwrap();
    assert!(matches!(
        s.send(&sid, "hello"),
        Err(QueueError::Db { code, .. }) if code == "55000"
    ));
    assert!(matches!(s.send(&id, ""), Err(QueueError::Db { .. })));
    let unread: i64 = pg
        .sql()
        .query_one("SELECT count(*) FROM inbox", &[])
        .unwrap()
        .get(0);
    assert_eq!(unread, 0);
}

#[test]
fn the_submitter_cli_starts_a_session_messages_it_and_waits_for_its_park() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let submitter = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_exec-pool"))
            .args(args)
            // no repository list: these submit example.org, which the pool host's list would refuse
            .env("EXEC_POOL_REPOS", "/nonexistent")
            .env(
                "EXEC_POOL_DB",
                pg.conninfo()
                    .replace("user=exec_pool ", "user=exec_pool_submit "),
            )
            .stderr(Stdio::null())
            .output()
            .unwrap();
        (out.status.code(), String::from_utf8(out.stdout).unwrap())
    };
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
    let (code, id) = submitter(&[
        "start",
        "--agent",
        "claude",
        "--repo",
        "https://example.org/r.git",
        "--rev",
        "abc",
        "--workdir",
        "w",
        "--prompt",
        "p",
    ]);
    assert_eq!(code, Some(0));
    let id = id.trim();
    let (a, epoch, _) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    let (code, out) = submitter(&["wait", id, "--timeout", "5"]);
    assert_eq!(code, Some(0), "wait returns on a park");
    let shown: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(
        (&shown["status"], &shown["parked"]),
        (&json!("waiting"), &json!("turn_end"))
    );
    assert_eq!(shown["result"]["output"], "the turn's answer");
    let (code, out) = submitter(&["send", id, "--prompt", "next"]);
    assert_eq!(code, Some(0));
    assert!(out.contains(r#""status":"queued""#), "{out}");
    let (a, epoch, turn) = started(&mut owner);
    assert_eq!(turn.input, "next");
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    let (code, out) = submitter(&["send", id, "--at", "23:59", "--prompt", "later"]);
    assert_eq!(code, Some(0));
    assert!(out.contains(r#""status":"waiting""#), "{out}");
    let due: bool = pg
        .sql()
        .query_one(
            "SELECT due_at > now() FROM inbox WHERE kind = 'timer' AND body = 'later'",
            &[],
        )
        .unwrap()
        .get(0);
    assert!(due, "HH:MM is the next such time");
    assert_eq!(
        submitter(&["send", id, "--at", "soon", "--prompt", "x"]).0,
        Some(2)
    );
}

#[test]
fn the_runner_runs_a_turn_and_neither_role_writes_or_reads_what_it_may_not() {
    let pg = Pg::new();
    let _owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let conninfo = pg
        .conninfo()
        .replace("user=exec_pool ", "user=exec_pool_runner ");
    let mut runner = Store::open(&conninfo).unwrap();
    let (a, epoch, _) = started(&mut runner);
    let (_, changes) = runner
        .park(&a, epoch, &park(ParkReason::HostDraining, 0))
        .unwrap();
    assert_eq!(changes.len(), 2, "its continue row wakes it");
    let (_, epoch, turn) = started(&mut runner);
    assert!(turn.upto > 0);
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting");
    s.send(&id, "next").unwrap();

    let refused = |conninfo: &str, sqls: &[String]| {
        let mut c = Client::connect(conninfo, NoTls).unwrap();
        for sql in sqls {
            let e = c.batch_execute(sql).unwrap_err();
            assert_eq!(
                e.code().map(postgres::error::SqlState::code),
                Some("42501"),
                "{sql}: {e}"
            );
        }
    };
    refused(
        &conninfo,
        &[
            format!("SELECT send_message('{id}', 'x')"),
            format!("SELECT start_session('{}')", agent_task()),
            "DELETE FROM inbox".to_owned(),
            "UPDATE inbox SET body = 'x'".to_owned(),
            "SELECT cost_usd FROM turns".to_owned(),
            "UPDATE turns SET delivered = false".to_owned(),
            format!("INSERT INTO inbox (task_id, kind, body) VALUES ('{id}', 'message', 'x')"),
            format!("SELECT send_timer('{id}', 'x', now())"),
        ],
    );
    refused(
        &pg.conninfo()
            .replace("user=exec_pool ", "user=exec_pool_submit "),
        &[
            "SELECT body FROM inbox".to_owned(),
            "SELECT * FROM inbox".to_owned(),
            format!("INSERT INTO inbox (task_id, kind) VALUES ('{id}', 'continue')"),
            "UPDATE tasks SET session = true".to_owned(),
            "SELECT * FROM turns".to_owned(),
            format!("SELECT wake_at('{id}', now(), NULL)"),
        ],
    );
}

#[test]
fn a_park_goes_only_through_park_and_a_cancelled_review_stays_cancelled() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    assert!(matches!(
        owner.apply(&a, &ev(epoch, Kind::Park(ParkReason::TurnEnd)), None),
        Err(QueueError::Contract(Error::IllegalTransition { .. }))
    ));
    assert_eq!(s.cancel(&id).unwrap(), (a.clone(), Status::Running));
    overdue(&pg, &a);
    owner.reconcile().unwrap();
    assert_eq!(status(&pg, &a).0, "needs_review");
    assert_eq!(
        s.send(&id, "go on").unwrap(),
        (a.clone(), Status::Cancelled)
    );
    assert!(owner.claim(&claude_slot(), 60).unwrap().is_none());
}

#[test]
fn a_park_marks_read_only_what_was_due_at_its_claim() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    pg.sql()
        .execute(
            "INSERT INTO inbox (task_id, kind, body, due_at) VALUES ($1, 'timer', 'later', now() + interval '1 hour')",
            &[&id],
        )
        .unwrap();
    s.send(&id, "now").unwrap();
    let (_, epoch, turn) = started(&mut owner);
    assert_eq!(turn.input, "now");
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting", "the timer is not due");
    let unread: i64 = pg
        .sql()
        .query_one(
            "SELECT count(*) FROM inbox WHERE consumed_epoch IS NULL AND kind = 'timer'",
            &[],
        )
        .unwrap()
        .get(0);
    assert_eq!(unread, 1, "the row not handed over stays unread");
}

fn unread_timers(pg: &Pg) -> i64 {
    pg.sql()
        .query_one(
            "SELECT count(*) FROM inbox WHERE kind = 'timer' AND consumed_epoch IS NULL",
            &[],
        )
        .unwrap()
        .get(0)
}

fn waking_at(due_at: &str, note: Option<&str>) -> Park {
    Park {
        wake: Some(Wake::new(due_at, note.map(str::to_owned)).unwrap()),
        ..park(ParkReason::TurnEnd, 0)
    }
}

#[test]
fn a_timer_wakes_its_session_once_due_and_a_message_before_it_does_not_spend_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let (_, changes) = owner
        .park(
            &a,
            epoch,
            &waking_at("2099-01-01T09:00:00+01:00", Some("check CI")),
        )
        .unwrap();
    assert_eq!(moves(&changes), [(Status::Waiting, "waiting_until")]);
    assert!(
        owner.reconcile().unwrap().is_empty(),
        "a future timer wakes nothing"
    );
    assert_eq!(status(&pg, &a).0, "waiting");
    assert_eq!(s.task(&id).unwrap().unwrap()["parked"], "waiting_until");

    assert_eq!(s.send(&id, "now").unwrap(), (a.clone(), Status::Queued));
    let (_, epoch, turn) = started(&mut owner);
    assert_eq!(
        turn.input, "now",
        "the timer is not due, so not handed over"
    );
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(status(&pg, &a).0, "waiting");
    assert_eq!(unread_timers(&pg), 1, "the message did not spend the timer");

    pg.sql()
        .execute(
            "UPDATE inbox SET due_at = now() - interval '1 second' WHERE kind = 'timer'",
            &[],
        )
        .unwrap();
    let changes = owner.reconcile().unwrap();
    assert_eq!(moves(&changes), [(Status::Queued, "wake")]);
    let (_, epoch, turn) = started(&mut owner);
    assert_eq!(turn.input, "check CI");
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert!(owner.reconcile().unwrap().is_empty(), "delivered once");
    assert_eq!(
        (status(&pg, &a).0.as_str(), unread_timers(&pg)),
        ("waiting", 0)
    );
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics.contains(
            "exec_pool_session_wake_seconds_count{host=\"msi-ms7758\",source=\"timer\"} 1"
        ),
        "{metrics}"
    );
}

#[test]
fn a_timer_already_due_wakes_at_the_park_or_the_next_reconcile() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let (_, changes) = owner
        .park(&a, epoch, &waking_at("2000-01-01T00:00:00Z", None))
        .unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "waiting_until"), (Status::Queued, "wake")]
    );
    let (_, epoch, turn) = started(&mut owner);
    assert_eq!(turn.input, "The time you asked to be woken at has come.");
    owner
        .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
        .unwrap();
    assert_eq!(
        s.send_timer(&id, "go on", "2000-01-01T00:00:00Z").unwrap(),
        (a.clone(), Status::Waiting),
        "a timer only inserts its row"
    );
    assert_eq!(
        moves(&owner.reconcile().unwrap()),
        [(Status::Queued, "wake")]
    );
    assert_eq!(started(&mut owner).2.input, "go on");
    assert!(matches!(
        s.send_timer(&id, "x", "not a time"),
        Err(QueueError::Db { .. })
    ));
}

#[test]
fn a_turn_error_counts_under_the_arm_its_slot_declared() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let _session = session(&pg);
    let (a, epoch, turn) = started(&mut owner);
    let mut errored = park(ParkReason::TurnError, turn.upto);
    errored.arm = Some(Arm::parse(r#"{"variant": "300000", "shunt": "off"}"#).unwrap());
    owner.park(&a, epoch, &errored).unwrap();
    let m = owner.metrics().unwrap();
    let has = |line: &str| assert!(m.lines().any(|l| l == line), "{line}\n{m}");
    has(
        "exec_pool_session_turn_errors_total{host=\"msi-ms7758\",variant=\"300000\",shunt=\"off\",agent=\"claude\"} 1",
    );
    has(
        "exec_pool_session_turn_errors_total{host=\"msi-ms7758\",variant=\"default\",shunt=\"off\",agent=\"claude\"} 0",
    );
    // it reported no usage, so it is no reported turn
    has(
        "exec_pool_session_turns_reported_total{host=\"msi-ms7758\",variant=\"300000\",shunt=\"off\",agent=\"claude\"} 0",
    );
}

#[test]
fn session_metrics_count_turns_wakes_and_tokens() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let mut reported = park(ParkReason::TurnEnd, 0);
    reported.result.usage = Some(Usage {
        input_tokens: 10,
        output_tokens: 200,
        cache_read_tokens: 3000,
        cache_creation_tokens: 400,
        cost_usd: Some(0.5),
    });
    reported.arm = Some(Arm::parse(r#"{"variant": "300000", "shunt": "off"}"#).unwrap());
    owner.park(&a, epoch, &reported).unwrap();
    s.send(&id, "next").unwrap();
    // the next turn on another host
    let mut elsewhere = claude_slot();
    elsewhere.host = "asus-b460m".to_owned();
    let claim = owner.claim(&elsewhere, 60).unwrap().unwrap();
    let epoch = claim.attempt.lease_epoch;
    owner.apply(&a, &ev(epoch, Kind::Start), None).unwrap();
    owner
        .park(
            &a,
            epoch,
            &park(ParkReason::Preempted, claim.turn.unwrap().upto),
        )
        .unwrap();
    let (_, epoch, turn) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();

    let m = owner.metrics().unwrap();
    let has = |line: &str| assert!(m.lines().any(|l| l == line), "{line}\n{m}");
    // each turn counts on the host its lease ran on, a waiting session on the one it last ran on
    has("exec_pool_sessions{host=\"msi-ms7758\",state=\"waiting\"} 1");
    has("exec_pool_sessions{host=\"msi-ms7758\",state=\"closed\"} 0");
    has("exec_pool_sessions_waiting{host=\"msi-ms7758\",reason=\"turn_end\"} 1");
    has("exec_pool_session_turns_total{host=\"msi-ms7758\",reason=\"turn_end\"} 2");
    has("exec_pool_session_turns_total{host=\"asus-b460m\",reason=\"preempted\"} 1");
    has("exec_pool_session_turn_seconds_count{host=\"msi-ms7758\",agent=\"claude\"} 2");
    has("exec_pool_session_turn_seconds_count{host=\"asus-b460m\",agent=\"claude\"} 1");
    has("exec_pool_session_wake_seconds_count{host=\"asus-b460m\",source=\"message\"} 1");
    has("exec_pool_session_wake_seconds_count{host=\"msi-ms7758\",source=\"continue\"} 1");
    has("exec_pool_session_wake_seconds_count{host=\"msi-ms7758\",source=\"timer\"} 0");
    has("exec_pool_session_host_changes_total{host=\"asus-b460m\"} 1");
    has("exec_pool_session_host_changes_total{host=\"msi-ms7758\"} 1");
    // usage by the host and arm its turn ran under; a turn that reported none counts no session there, and a host
    // with no turn under an arm reads zero only for its default one
    let arm = "variant=\"300000\",shunt=\"off\"";
    has(&format!(
        "exec_pool_session_turns_reported_total{{host=\"msi-ms7758\",{arm},agent=\"claude\"}} 1"
    ));
    has(&format!(
        "exec_pool_session_cache_read_tokens_total{{host=\"msi-ms7758\",{arm},agent=\"claude\"}} 3000"
    ));
    has(&format!(
        "exec_pool_session_cost_usd_total{{host=\"msi-ms7758\",{arm},agent=\"claude\"}} 0.5"
    ));
    has(&format!(
        "exec_pool_sessions_reported_last_day{{host=\"msi-ms7758\",{arm},agent=\"claude\"}} 1"
    ));
    has(
        "exec_pool_session_turns_reported_total{host=\"asus-b460m\",variant=\"unknown\",shunt=\"unknown\",agent=\"claude\"} 0",
    );
    has(
        "exec_pool_sessions_reported_last_day{host=\"msi-ms7758\",variant=\"default\",shunt=\"off\",agent=\"claude\"} 0",
    );
    assert!(!m.contains("host=\"asus-b460m\",variant=\"300000\""), "{m}");
    // only the first turn reported usage, so no session ran under two arms
    has("exec_pool_sessions_mixed_arms_last_day 0");
    has(
        "exec_pool_sessions_parked_seconds_bucket{host=\"msi-ms7758\",agent=\"claude\",le=\"86400\"} 1",
    );
    assert!(!m.contains(&id), "no id in a label");
}

#[test]
fn a_session_summary_splits_its_time_by_state_and_park_reason_and_sums_its_usage() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let mut reported = park(ParkReason::TurnEnd, 0);
    reported.result.usage = Some(Usage {
        input_tokens: 10,
        output_tokens: 200,
        cache_read_tokens: 3000,
        cache_creation_tokens: 400,
        cost_usd: Some(0.5),
    });
    owner.park(&a, epoch, &reported).unwrap();
    s.send(&id, "next").unwrap();
    let (_, epoch, turn) = started(&mut owner);
    let mut second = park(ParkReason::TurnError, turn.upto);
    second.result.usage = Some(Usage {
        input_tokens: 1,
        output_tokens: 2,
        cache_read_tokens: 3,
        cache_creation_tokens: 4,
        cost_usd: Some(0.25),
    });
    owner.park(&a, epoch, &second).unwrap();
    // every state left lasted a second: queued, leased, running and waiting once a turn, the first wait a turn_end
    pg.sql()
        .execute(
            "UPDATE events SET in_state_ms = 1000 WHERE from_status IS NOT NULL",
            &[],
        )
        .unwrap();

    let all = s.session_summaries(None, 20).unwrap();
    assert_eq!(all.len(), 1, "{all:?}");
    let v = &all[0];
    assert_eq!(
        s.session_summaries(Some(&a), 20).unwrap()[0]["task"],
        id.as_str(),
        "by its attempt too"
    );
    assert!(
        s.session_summaries(Some("cli-none"), 20)
            .unwrap()
            .is_empty()
    );
    assert_eq!(v["task"], id.as_str());
    assert_eq!(v["state"], "waiting");
    assert_eq!(v["agent"], "claude");
    assert_eq!(v["last_host"], "msi-ms7758");
    assert_eq!(v["turns"], 2);
    assert_eq!(v["turns_reported"], 2);
    assert_eq!(v["input_tokens"], 11);
    assert_eq!(v["output_tokens"], 202);
    assert_eq!(v["cache_read_tokens"], 3003);
    assert_eq!(v["cache_creation_tokens"], 404);
    assert_eq!(v["cost_usd"], 0.75);
    assert_eq!(v["model"], "opus");
    assert_eq!(v["session"], true);
    let secs = |k: &str| v[k].as_f64().unwrap_or_else(|| panic!("{k}: {v}"));
    // a lease is leased then running, twice
    assert!((secs("running_seconds") - 4.0).abs() < 1e-9, "{v}");
    assert!((secs("queued_seconds") - 2.0).abs() < 1e-9, "{v}");
    assert!(secs("review_seconds").abs() < 1e-9, "{v}");
    // the first wait, and the one it is still in, counted up to now
    let by = &v["waiting_by_reason"];
    assert!((by["turn_end"].as_f64().unwrap() - 1.0).abs() < 1e-9, "{v}");
    let now = by["turn_error"].as_f64().unwrap();
    assert!((0.0..60.0).contains(&now), "{v}");
    assert!((secs("waiting_seconds") - 1.0 - now).abs() < 1e-6, "{v}");
    assert!(secs("wall_seconds") >= 0.0);
    // the runner reads no summary
    let mut runner = Store::open(
        &pg.conninfo()
            .replace("user=exec_pool ", "user=exec_pool_runner "),
    )
    .unwrap();
    assert!(runner.session_summaries(None, 20).is_err());
}

#[test]
fn a_one_shot_agent_task_is_summarised_with_its_model_and_a_none_task_is_not() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    submit(&mut owner, &task("t-none", 1));
    let (mut s, _) = submitter(&pg);
    let mut bare = agent_task();
    bare["idempotency_key"] = json!("cli:2");
    bare["command"]["argv"] = json!([ARGV_MARKER]);
    let (id, _) = s
        .submit_task(&serde_json::from_value(bare).unwrap(), 0)
        .unwrap();
    let all = s.session_summaries(None, 20).unwrap();
    assert_eq!(all.len(), 2, "{all:?}");
    let shown = serde_json::to_string(&all).unwrap();
    assert!(!shown.contains(ARGV_MARKER), "{shown}");
    let v = &s.session_summaries(Some(&id), 20).unwrap()[0];
    assert_eq!(v["session"], false);
    assert_eq!(v["agent"], "claude");
    assert_eq!(v["model"], "default", "no model named: the agent's own");
    assert_eq!(v["state"], "queued");
    assert!(
        v["cost_usd"].is_null(),
        "no turn reported: unpriced, not free"
    );
    assert!(all.iter().any(|v| v["model"] == "opus"), "{all:?}");
}

#[test]
fn reported_cost_sums_exactly_so_its_counter_never_drops() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, _) = started(&mut owner);
    let cost = |c: f64| {
        let mut p = park(ParkReason::TurnEnd, 0);
        p.result.usage = Some(Usage {
            cost_usd: Some(c),
            ..Usage::default()
        });
        p
    };
    owner.park(&a, epoch, &cost(0.1)).unwrap();
    s.send(&id, "next").unwrap();
    let (_, epoch, turn) = started(&mut owner);
    let mut second = cost(0.2);
    second.upto = turn.upto;
    owner.park(&a, epoch, &second).unwrap();
    // 0.1 + 0.2 in float8 reads 0.30000000000000004, and another order of a longer sum a bit less
    let m = owner.metrics().unwrap();
    assert!(
        m.lines().any(
            |l| l.starts_with("exec_pool_session_cost_usd_total{host=\"msi-ms7758\"")
                && l.ends_with(",agent=\"claude\"} 0.3")
        ),
        "{m}"
    );
    assert_eq!(
        s.session_summaries(Some(&id), 20).unwrap()[0]["cost_usd"],
        0.3
    );
}

#[test]
fn the_sessions_cli_finds_the_pull_request_and_reports_a_merged_session_once() {
    use std::os::unix::fs::PermissionsExt as _;
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_, id) = session(&pg);
    let dir = std::env::temp_dir().join(format!("exec-pool-sessions-{id}"));
    std::fs::create_dir_all(&dir).unwrap();
    let gh = dir.join("gh");
    std::fs::write(
        &gh,
        format!(
            "#!/bin/sh\necho \"$@\" >> {}/argv\necho '[{{\"number\":7,\"state\":\"closed\",\"merged_at\":\"2026-11-25T06:40:00Z\",\"html_url\":\"u\"}}]'\n",
            dir.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let run = |path: &std::path::Path, args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_exec-pool"))
            .args(args)
            .env("PATH", path)
            .env(
                "EXEC_POOL_DB",
                pg.conninfo()
                    .replace("user=exec_pool ", "user=exec_pool_submit "),
            )
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
            .collect::<Vec<_>>()
    };
    let report = dir.join("reported");
    let report_arg = report.to_str().unwrap();
    // queued: not yet reported, whatever its pull request
    assert!(run(&dir, &["sessions", "--report", report_arg]).is_empty());
    let (a, epoch, _) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, 0))
        .unwrap();
    let listed = run(&dir, &["sessions"]);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["task"], id.as_str());
    assert_eq!(listed[0]["pr"]["number"], 7);
    assert_eq!(listed[0]["pr"]["state"], "merged");
    let argv = std::fs::read_to_string(dir.join("argv")).unwrap();
    assert!(
        argv.contains(&format!(
            "repos/sammasak/nixos-config/pulls -f head=sammasak:pool/{id} -f state=all"
        )),
        "{argv}"
    );
    assert_eq!(run(&dir, &["sessions", "--merged", &id]).len(), 1);
    let reported = run(&dir, &["sessions", "--report", report_arg]);
    assert_eq!(reported.len(), 1);
    assert_eq!(std::fs::read_to_string(&report).unwrap(), format!("{id}\n"));
    assert!(
        run(&dir, &["sessions", "--report", report_arg]).is_empty(),
        "once"
    );
    // no gh: the summary still, its pull request unknown and why
    let empty = dir.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let bare = run(&empty, &["sessions"]);
    assert_eq!(bare[0]["pr"], serde_json::Value::Null);
    assert!(
        bare[0]["pr_error"].as_str().unwrap().starts_with("gh: "),
        "{bare:?}"
    );
    assert!(run(&empty, &["sessions", "--merged"]).is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_turns_log_is_read_by_the_submitter_while_it_runs_and_after() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let mut runner = Store::open(
        &pg.conninfo()
            .replace("user=exec_pool ", "user=exec_pool_runner "),
    )
    .unwrap();
    let (mut s, id) = session(&pg);
    assert_eq!(
        s.logs(&id, None).unwrap(),
        Logs {
            pending: true,
            turn: None
        }
    );
    assert!(matches!(s.logs("nope", None), Err(QueueError::NotFound(_))));
    let (a, e1, _) = started(&mut owner);
    runner.put_log(&a, e1, 0, b"first").unwrap();
    runner.put_log(&a, e1, 100, b"later tail").unwrap();
    // a read the runner took before the last is not put back
    runner.put_log(&a, e1, 0, b"first").unwrap();
    let live = s.logs(&id, None).unwrap().turn.unwrap();
    assert_eq!(
        (
            live.turn,
            live.turns,
            live.start,
            live.log.as_slice(),
            live.live
        ),
        (1, 1, 100, b"later tail".as_slice(), true)
    );
    assert!(matches!(
        runner.put_log(&a, e1 + 1, 0, b"x"),
        Err(QueueError::Fenced(_))
    ));
    let over = vec![b'x'; usize::try_from(exec_pool::turn_log::LOG_BYTES).unwrap() + 1];
    assert!(runner.put_log(&a, e1, 200, &over).is_err());
    owner.park(&a, e1, &park(ParkReason::TurnEnd, 0)).unwrap();
    assert_eq!(
        s.logs(&id, None).unwrap(),
        Logs {
            pending: false,
            turn: Some(TurnLog {
                live: false,
                ..live
            })
        }
    );
    s.send(&id, "next").unwrap();
    let (a2, e2, _) = started(&mut owner);
    assert_eq!(a2, a);
    runner.put_log(&a, e2, 0, b"second").unwrap();
    let last = s.logs(&a, None).unwrap().turn.unwrap();
    assert_eq!(
        (last.turn, last.turns, last.log.as_slice()),
        (2, 2, b"second".as_slice())
    );
    let first = s.logs(&id, Some(1)).unwrap().turn.unwrap();
    assert_eq!((first.lease_epoch, first.live), (e1, false));
    assert_eq!(s.logs(&id, Some(3)).unwrap().turn, None);
}

/// Sets the priority of task `id` and how long its attempt has waited queued, as a submission and the clock would.
fn queued_for(pg: &Pg, id: &str, priority: i32, minutes: i32) {
    let mut c = pg.sql();
    c.execute(
        "UPDATE tasks SET priority = $2 WHERE id = $1",
        &[&id, &priority],
    )
    .unwrap();
    c.execute(
        "UPDATE attempts SET changed_at = now() - make_interval(mins => $2), fence = lease_epoch WHERE task_id = $1",
        &[&id, &minutes],
    )
    .unwrap();
}

fn claimed(s: &mut Store, slot_id: &str) -> String {
    s.claim(&slot(slot_id), 60).unwrap().unwrap().task.id
}

#[test]
fn a_claim_takes_the_highest_priority_first_then_the_oldest() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    for (id, priority, minutes) in [("low", 0, 3), ("high", 5, 2), ("high-later", 5, 1)] {
        submit(&mut s, &task(id, 1));
        queued_for(&pg, id, priority, minutes);
    }
    assert_eq!(claimed(&mut s, "s0"), "high");
    assert_eq!(claimed(&mut s, "s1"), "high-later");
    assert_eq!(claimed(&mut s, "s2"), "low");
}

#[test]
fn a_waiting_task_gains_one_priority_step_per_ten_minutes() {
    let pg = Pg::new();
    let mut s = pg.migrated();
    // 49 minutes: 4 steps, still behind a fresh 5
    for (id, priority, minutes) in [("waited-49", 0, 49), ("fresh-5", 5, 0)] {
        submit(&mut s, &task(id, 1));
        queued_for(&pg, id, priority, minutes);
    }
    assert_eq!(claimed(&mut s, "s0"), "fresh-5");
    // 61 minutes: 6 steps, ahead of it
    for (id, priority, minutes) in [("waited-61", 0, 61), ("fresh-5b", 5, 0)] {
        submit(&mut s, &task(id, 1));
        queued_for(&pg, id, priority, minutes);
    }
    assert_eq!(claimed(&mut s, "s1"), "waited-61");
    assert_eq!(claimed(&mut s, "s2"), "fresh-5b");
    assert_eq!(claimed(&mut s, "s3"), "waited-49");
}

#[test]
fn the_submitter_sets_a_priority_once_and_within_its_bound() {
    let pg = Pg::new();
    pg.migrated();
    let (mut s, id) = submitter(&pg);
    let priority = |id: &str| -> i32 {
        pg.sql()
            .query_one("SELECT priority FROM tasks WHERE id = $1", &[&id])
            .unwrap()
            .get(0)
    };
    assert_eq!(priority(&id), 0);
    let mut other: TaskSpec = serde_json::from_value(agent_task()).unwrap();
    other.idempotency_key = "cli:urgent".to_owned();
    let (urgent, _) = s.submit_task(&other, 7).unwrap();
    assert_eq!(priority(&urgent), 7);
    assert_eq!(s.submit_task(&other, -3).unwrap(), (urgent.clone(), true));
    assert_eq!(
        priority(&urgent),
        7,
        "the same key keeps its first priority"
    );
    other.idempotency_key = "cli:too-high".to_owned();
    assert!(
        matches!(s.submit_task(&other, 101), Err(QueueError::Db { code, .. }) if code == "22023")
    );
    other.idempotency_key = "cli:session".to_owned();
    let (session, _) = s.start_session(&other, -100).unwrap();
    assert_eq!(priority(&session), -100);
    // the submitter reads it back in status and list, through task_summaries
    assert_eq!(s.task(&urgent).unwrap().unwrap()["priority"], 7);
    assert_eq!(s.tasks(1).unwrap()[0]["priority"], -100);
}

#[test]
fn a_parked_transcript_is_bounded_kept_compressed_handed_to_the_next_turn_and_dropped_once_final() {
    let pg = Pg::new();
    let _owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    let (a, epoch, first) = started(&mut runner);
    assert_eq!(
        first.transcript, None,
        "nothing to resume on the first turn"
    );
    // as compressible as a transcript's JSON lines
    let body = "{\"type\":\"assistant\",\"message\":{\"content\":\"the same line again\"}}\n"
        .repeat(20_000)
        .into_bytes();
    let t = Transcript {
        project: "-session-cur-work".to_owned(),
        body: body.clone(),
    };
    let with = |t: Transcript, upto| Park {
        transcript: Some(t),
        ..park(ParkReason::TurnEnd, upto)
    };
    let over = Transcript {
        body: vec![b'x'; TRANSCRIPT_BYTES + 1],
        ..t.clone()
    };
    assert!(matches!(
        runner.park(&a, epoch, &with(over, first.upto)),
        Err(QueueError::Range("transcript"))
    ));
    let outside = Transcript {
        project: "..".to_owned(),
        ..t.clone()
    };
    assert!(matches!(
        runner.park(&a, epoch, &with(outside, first.upto)),
        Err(QueueError::Range("transcript project"))
    ));
    runner
        .park(&a, epoch, &with(t.clone(), first.upto))
        .expect("a refused transcript left the turn live");
    let (raw, stored): (i32, i32) = pg
        .sql()
        .query_one(
            "SELECT octet_length(body), pg_column_size(body) FROM transcripts",
            &[],
        )
        .map(|r| (r.get(0), r.get(1)))
        .unwrap();
    assert_eq!(usize::try_from(raw).unwrap(), body.len());
    assert!(
        stored < raw / 10,
        "kept compressed: {stored} of {raw} bytes"
    );

    s.send(&id, "next").unwrap();
    let (a, epoch, second) = started(&mut runner);
    assert_eq!(second.transcript.as_ref(), Some(&t), "on any host's claim");
    runner
        .park(&a, epoch, &park(ParkReason::TurnError, second.upto))
        .unwrap();
    s.send(&id, "again").unwrap();
    let (a, epoch, third) = started(&mut runner);
    assert_eq!(
        third.transcript.map(|t| t.body),
        Some(body),
        "a park with no transcript keeps the last one"
    );
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, third.upto))
        .unwrap();
    s.cancel(&id).unwrap();
    let left: i64 = pg
        .sql()
        .query_one("SELECT count(*) FROM transcripts", &[])
        .unwrap()
        .get(0);
    assert_eq!(left, 0, "a final session is never resumed");
}

#[test]
fn a_session_whose_pane_or_prompt_keeps_failing_parks_and_a_send_wakes_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    // max_attempts is 1: a failed turn that went back to the queue would end the session `failed` at once
    for (n, step) in exec_pool::runner::PANE_STEPS
        .iter()
        .cycle()
        .take(4)
        .enumerate()
    {
        let (a, epoch, turn) = started(&mut owner);
        let result: exec_pool::runner::ExecResult = serde_json::from_value(json!({
            "schema_version": 1, "attempt_id": a, "lease_epoch": epoch, "stage": "prepare",
            "exit_code": 1, "timed_out": false, "cancelled": false, "failed_step": step,
            "container_active": true, "stdout_tail": "", "stderr_tail": "", "prepare_ms": 5000, "run_ms": 0
        }))
        .unwrap();
        let to = exec_pool::runner::decide_turn(&a, epoch, Some(&result), "");
        assert_eq!(
            to,
            exec_pool::runner::TurnSettle::Park(ParkReason::TurnError)
        );
        owner
            .park(&a, epoch, &park(ParkReason::TurnError, turn.upto))
            .unwrap();
        assert_eq!(status(&pg, &a).0, "waiting", "turn {n}, failed at {step}");
        assert_eq!(
            s.send(&id, &format!("try {n}")).unwrap(),
            (a.clone(), Status::Queued)
        );
    }
}

#[test]
fn a_turn_whose_input_never_reached_the_agent_hands_it_to_the_next() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let undelivered = |upto| Park {
        undelivered: true,
        ..park(ParkReason::TurnError, upto)
    };
    let (a, epoch, first) = started(&mut owner);
    assert!(first.first);
    owner.park(&a, epoch, &undelivered(first.upto)).unwrap();
    s.send(&id, "one").unwrap();
    let (a, epoch, again) = started(&mut owner);
    assert!(
        again.first,
        "the prompt never reached it: still the first turn"
    );
    assert_eq!(again.input, first.input);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, again.upto))
        .unwrap();
    s.send(&id, "two").unwrap();
    let (a, epoch, later) = started(&mut owner);
    assert!(!later.first);
    assert!(later.input.contains("two"), "{}", later.input);
    owner.park(&a, epoch, &undelivered(later.upto)).unwrap();
    s.send(&id, "three").unwrap();
    let (_, _, next) = started(&mut owner);
    assert!(
        next.input.contains("two") && next.input.contains("three"),
        "the undelivered message is handed again: {}",
        next.input
    );
}

#[test]
fn an_arm_is_two_bounded_labels_and_nothing_else() {
    assert_eq!(
        Arm::parse(r#"{"variant": "default", "shunt": "on"}"#).unwrap(),
        Arm {
            variant: "default".to_owned(),
            shunt: "on".to_owned()
        }
    );
    for bad in [
        r#"{"variant": "", "shunt": "off"}"#,
        r#"{"variant": "300\"} 1", "shunt": "off"}"#,
        r#"{"variant": "Default", "shunt": "off"}"#,
        r#"{"variant": "12345678901234567", "shunt": "off"}"#,
        r#"{"variant": "default", "shunt": "yes"}"#,
        r#"{"variant": "default", "shunt": "off", "slot": "pool2"}"#,
        r#"{"variant": "default"}"#,
    ] {
        assert!(Arm::parse(bad).is_err(), "{bad}");
    }
}

#[test]
fn a_park_with_an_arm_lands_in_a_queue_not_yet_migrated_to_record_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, _id) = session(&pg);
    // as a remote runner's park into a queue host still at 20
    pg.sql()
        .batch_execute("ALTER TABLE turns DROP COLUMN variant, DROP COLUMN shunt")
        .unwrap();
    let (a, epoch, _) = started(&mut owner);
    let mut armed = park(ParkReason::TurnEnd, 0);
    armed.arm = Some(Arm::parse(r#"{"variant": "300000", "shunt": "off"}"#).unwrap());
    owner.park(&a, epoch, &armed).unwrap();
    let turns: i64 = pg
        .sql()
        .query_one("SELECT count(*) FROM turns", &[])
        .unwrap()
        .get(0);
    assert_eq!(turns, 1);
}

#[test]
fn an_undelivered_turn_keeps_the_error_backoff_and_past_it_counts_as_stalled() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let mut runner = runner(&pg);
    let undelivered = |upto| Park {
        undelivered: true,
        ..park(ParkReason::TurnError, upto)
    };
    let stalled = |m: &str| {
        m.lines()
            .any(|l| l == "exec_pool_sessions_stalled{host=\"msi-ms7758\",reason=\"turn_error\"} 1")
    };
    let (a, epoch, first) = started(&mut runner);
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, first.upto))
        .unwrap();
    s.send(&id, "the message").unwrap();
    for (n, secs) in exec_pool::queue::ERROR_BACKOFF_SECS.iter().enumerate() {
        let (a, epoch, turn) = started(&mut runner);
        assert!(
            turn.input.contains("the message"),
            "turn {n}: {}",
            turn.input
        );
        let (_, changes) = runner.park(&a, epoch, &undelivered(turn.upto)).unwrap();
        assert_eq!(
            moves(&changes),
            [(Status::Waiting, "turn_error")],
            "turn {n}: not queued again at once"
        );
        let held: i64 = pg
            .sql()
            .query_one(
                "SELECT extract(epoch FROM due_at - now())::int8 FROM inbox \
                 WHERE kind = 'message' AND consumed_epoch IS NULL",
                &[],
            )
            .unwrap()
            .get(0);
        assert!(
            (i64::from(*secs) - 60..=i64::from(*secs)).contains(&held),
            "turn {n}: the message held {held} s, not {secs}"
        );
        assert!(runner.claim(&claude_slot(), 60).unwrap().is_none());
        assert!(owner.reconcile().unwrap().is_empty());
        assert!(
            !stalled(&owner.metrics().unwrap()),
            "turn {n}: a continue is to come"
        );
        pg.sql()
            .execute(
                "UPDATE inbox SET due_at = now() - interval '1 second' WHERE consumed_epoch IS NULL",
                &[],
            )
            .unwrap();
        assert_eq!(
            moves(&owner.reconcile().unwrap()),
            [(Status::Queued, "wake")]
        );
    }
    let (a, epoch, turn) = started(&mut runner);
    let (_, changes) = runner.park(&a, epoch, &undelivered(turn.upto)).unwrap();
    assert_eq!(moves(&changes), [(Status::Waiting, "turn_error")]);
    assert!(
        owner.reconcile().unwrap().is_empty(),
        "held past the backoff"
    );
    let metrics = owner.metrics().unwrap();
    assert!(stalled(&metrics), "{metrics}");
    s.send(&id, "and this").unwrap();
    assert!(!stalled(&owner.metrics().unwrap()), "a message moves it");
    let unread = |cond: &str| -> i64 {
        let sql = format!("SELECT count(*) FROM inbox WHERE consumed_epoch IS NULL {cond}");
        pg.sql().query_one(&sql, &[]).unwrap().get(0)
    };
    assert_eq!(
        unread("AND due_at > now()"),
        0,
        "the message makes it due in the queue, for a runner at any version"
    );
    let (a, epoch, turn) = started(&mut runner);
    assert!(
        turn.input.contains("the message") && turn.input.contains("and this"),
        "the held message comes with the new one: {}",
        turn.input
    );
    runner
        .park(&a, epoch, &park(ParkReason::TurnEnd, turn.upto))
        .unwrap();
    assert_eq!(unread(""), 0, "both read once delivered");
}

#[test]
fn a_second_session_stalling_on_the_same_host_and_reason_is_its_own_series() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, first) = session(&pg);
    let mut other = agent_task();
    other["idempotency_key"] = json!("cli:2");
    let (second, _) = s
        .start_session(&serde_json::from_value(other).unwrap(), 0)
        .unwrap();
    let mut runner = runner(&pg);
    let per_session = |m: &str| -> Vec<String> {
        m.lines()
            .filter(|l| l.starts_with("exec_pool_session_stalled{"))
            .map(str::to_owned)
            .collect()
    };
    // the two take turns: each continue queues its session behind the other
    for _ in 0..2 * TIMEOUTS_IN_A_ROW {
        time_out(&mut runner);
    }
    let mut ids = [&first, &second];
    ids.sort();
    assert_eq!(
        per_session(&owner.metrics().unwrap()),
        ids.iter()
            .map(|t| format!(
                "exec_pool_session_stalled{{host=\"msi-ms7758\",reason=\"turn_timeout\",task=\"{t}\"}} 1"
            ))
            .collect::<Vec<_>>(),
        "each stalled session its own series, so the alert pages the second too"
    );
    s.send(&first, "go on").unwrap();
    assert_eq!(
        per_session(&owner.metrics().unwrap()).len(),
        1,
        "only while stalled"
    );
}

#[test]
fn an_undelivered_park_lands_in_a_queue_not_yet_migrated_to_hold_it() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    // as a remote runner's park into a queue host still at 24
    pg.sql()
        .batch_execute("DROP FUNCTION hold_input(text, text, int8, int8, int8)")
        .unwrap();
    let (a, epoch, first) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, first.upto))
        .unwrap();
    s.send(&id, "the message").unwrap();
    let (a, epoch, turn) = started(&mut owner);
    let undelivered = Park {
        undelivered: true,
        ..park(ParkReason::TurnError, turn.upto)
    };
    let (_, changes) = owner.park(&a, epoch, &undelivered).unwrap();
    assert_eq!(
        moves(&changes),
        [(Status::Waiting, "turn_error"), (Status::Queued, "wake")],
        "there it wakes at once, as before"
    );
}

#[test]
fn a_message_during_a_turn_releases_held_input_for_the_next_turn_not_that_one() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (mut s, id) = session(&pg);
    let (a, epoch, first) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, first.upto))
        .unwrap();
    s.send(&id, "held").unwrap();
    let (a, epoch, turn) = started(&mut owner);
    let undelivered = Park {
        undelivered: true,
        ..park(ParkReason::TurnError, turn.upto)
    };
    owner.park(&a, epoch, &undelivered).unwrap();
    // a timer due now wakes it before the hold ends: its turn is handed the timer alone
    pg.sql()
        .execute(
            "INSERT INTO inbox (task_id, kind, due_at) VALUES ($1, 'timer', now())",
            &[&id],
        )
        .unwrap();
    assert_eq!(
        moves(&owner.reconcile().unwrap()),
        [(Status::Queued, "wake")]
    );
    let (a, epoch, timer) = started(&mut owner);
    assert!(!timer.input.contains("held"), "{}", timer.input);
    s.send(&id, "later").unwrap();
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, timer.upto))
        .unwrap();
    let (_, _, next) = started(&mut owner);
    assert!(
        next.input.contains("held") && next.input.contains("later"),
        "the turn that was not handed it did not mark it read: {}",
        next.input
    );
}

#[test]
fn input_held_past_the_backoff_stalls_its_session_after_a_timer_turn_too() {
    let pg = Pg::new();
    let mut owner = pg.migrated();
    let (_s, id) = session(&pg);
    let (a, epoch, first) = started(&mut owner);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, first.upto))
        .unwrap();
    // as hold_input leaves it past the backoff, then a timer comes due
    pg.sql()
        .batch_execute(&format!(
            "INSERT INTO inbox (task_id, kind, body, due_at) VALUES ('{id}', 'message', 'held', 'infinity'); \
             INSERT INTO inbox (task_id, kind, due_at) VALUES ('{id}', 'timer', now())"
        ))
        .unwrap();
    owner.reconcile().unwrap();
    let (a, epoch, timer) = started(&mut owner);
    assert!(!timer.input.contains("held"), "{}", timer.input);
    owner
        .park(&a, epoch, &park(ParkReason::TurnEnd, timer.upto))
        .unwrap();
    let metrics = owner.metrics().unwrap();
    assert!(
        metrics.lines().any(|l| l
            == format!(
                "exec_pool_session_stalled{{host=\"msi-ms7758\",reason=\"turn_end\",task=\"{id}\"}} 1"
            )),
        "{metrics}"
    );
}
