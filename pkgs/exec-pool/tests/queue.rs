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

use exec_pool::queue::{QueueError, Store, Submitted};
use exec_pool::{
    Agent, Error, Event, Kind, Pins, Receipt, Resolution, SchemaVersion, Settle, Slot, SlotState,
    Status, TaskSpec,
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
            "SELECT count(*) FROM pg_tables WHERE tablename IN ('tasks', 'attempts', 'events', 'receipts')",
            &[],
        )
        .unwrap()
        .get(0)
    };
    assert_eq!(tables(&mut pg.sql()), 4);
    s.migrate_down().unwrap();
    assert_eq!(tables(&mut pg.sql()), 0);
    s.migrate().unwrap();
    submit(&mut s, &task("t-1", 1));
    pg.sql()
        .execute("INSERT INTO schema_migrations (version) VALUES (2)", &[])
        .unwrap();
    assert!(matches!(s.migrate(), Err(QueueError::SchemaAhead(2))));
    assert!(matches!(s.migrate_down(), Err(QueueError::SchemaAhead(2))));
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
fn a_state_change_carries_ids_and_the_history_no_prompt() {
    let pg = Pg::new();
    let mut s = pg.migrated();
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
    s.heartbeat(&a, 1, 3600).unwrap();
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
