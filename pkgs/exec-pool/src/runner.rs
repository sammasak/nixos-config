//! What the pool runner (#652) and its slot-control helper agree on, and the runner's decisions.
//!
//! Apart from the host, so they are tested without one. The runner (`exec_pool`, the queue's peer role) claims an attempt, writes a
//! [`Manifest`] and starts `exec-pool-exec@<slot>`; that helper (root, no queue access) runs the task in the slot's
//! guest as its user and writes an [`ExecResult`]; the runner settles the attempt from it with [`decide`] and releases
//! the slot with `dev-env-reset@<slot>`. Each attempt runs in its own [`Workspace`], which that reset removes with the
//! home.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Read as _};
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::workspace::{self, Workspace};
use crate::{
    Agent, Error, Outcome, Receipt, SchemaVersion, Settle, TaskSpec, agent, parse_versioned,
};

/// How much of each output stream the result carries; the host keeps up to [`CAPTURE_BYTES`] of it.
pub const TAIL_BYTES: usize = 2048;
pub const CAPTURE_BYTES: u64 = 1 << 20;
/// The largest manifest or result read: both are a few KiB.
const READ_LIMIT: u64 = 1 << 20;

/// One attempt as the runner hands it to the helper.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema_version: SchemaVersion,
    pub slot: String,
    pub attempt_id: String,
    pub lease_epoch: u64,
    pub task: TaskSpec,
}

impl Manifest {
    /// # Errors
    /// What [`parse_versioned`] or [`TaskSpec::validate`] (against the task's own capabilities: the queue checked
    /// the grant at submit) or [`agent::argv`] rejects, and a `rev` that would read as an option.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let m: Self = parse_versioned(json)?;
        m.task.validate(&m.task.capabilities)?;
        agent::argv(&m.task).map_err(|e| Error::Json(e.to_string()))?;
        if m.task.source.rev.starts_with('-') {
            return Err(Error::Json(format!(
                "source.rev {:?} starts with '-'",
                m.task.source.rev
            )));
        }
        Ok(m)
    }

    /// The host directory its output goes to: hex of the attempt id, then the epoch, one path component whatever
    /// the id holds.
    #[must_use]
    pub fn run_dir(&self) -> String {
        let mut s = String::new();
        for b in self.attempt_id.bytes() {
            let _ = write!(s, "{b:02x}");
        }
        let _ = write!(s, "-{}", self.lease_epoch);
        s
    }

    /// What the runner writes to its cancel marker to have the helper stop this attempt, and no other.
    #[must_use]
    pub fn cancel_token(&self) -> String {
        format!("{} {}\n", self.attempt_id, self.lease_epoch)
    }

    /// The attempt's workspace under the guest user's home.
    ///
    /// # Errors
    /// What [`Workspace::new`] rejects.
    pub fn workspace(&self, guest_home: &str) -> Result<Workspace, workspace::Error> {
        Workspace::new(guest_home, &self.attempt_id, self.lease_epoch)
    }

    /// The guest commands in order: create the workspace, clone into it, check out, then [`agent::argv`] in the task's
    /// workdir with the workspace's HOME. Each is an argv, never a shell string; `git`, `env` and `mkdir` are store
    /// paths the guest shares. Git reads no global or system config: the guest user's rewrites https GitHub URLs to
    /// ssh, and a slot holds no key, so the clone is anonymous https.
    ///
    /// # Errors
    /// What [`agent::argv`] or [`Workspace::run`] rejects.
    pub fn steps(
        &self,
        ws: &Workspace,
        git: &str,
        env: &str,
        mkdir: &str,
    ) -> Result<[(Stage, Vec<String>); 5], StepsError> {
        let s = |v: &[&str]| v.iter().map(|&x| x.to_owned()).collect::<Vec<_>>();
        let git = |args: &[&str]| {
            let mut v = s(&[
                env,
                "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_CONFIG_NOSYSTEM=1",
                git,
            ]);
            v.extend(s(args));
            v
        };
        let t = &self.task;
        let checkout = ws.checkout();
        let run = ws.run(env, &t.command.workdir, &agent::argv(t)?)?;
        let [root, dirs] = ws.create(mkdir);
        Ok([
            (Stage::Prepare, root),
            (Stage::Prepare, dirs),
            (
                Stage::Prepare,
                git(&["clone", "--quiet", "--", &t.source.repo, &checkout]),
            ),
            (
                Stage::Prepare,
                git(&[
                    "-C",
                    &checkout,
                    "checkout",
                    "--quiet",
                    "--detach",
                    &t.source.rev,
                ]),
            ),
            (Stage::Run, run),
        ])
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum StepsError {
    #[error(transparent)]
    Agent(#[from] agent::Error),
    #[error(transparent)]
    Workspace(#[from] workspace::Error),
}

/// The exit code `systemd-run --wait --service-type=oneshot` reports for its unit, `None` for none.
///
/// 255 is `EXIT_EXCEPTION`, killed by a signal, so also `None`. Only exit 0 is a clean exit for a oneshot unit, so a
/// command a stopping guest killed with SIGTERM does not read as a success; a command's own 255 reads as unknown.
#[must_use]
pub fn guest_exit(code: Option<i32>) -> Option<i32> {
    code.filter(|&c| c != 255)
}

/// Where a run stopped. `Prepare`: the task's own argv never started, so nothing of it can have had an effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Prepare,
    Run,
}

/// What the helper reports for one attempt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExecResult {
    pub schema_version: SchemaVersion,
    pub attempt_id: String,
    pub lease_epoch: u64,
    /// The last stage that started.
    pub stage: Stage,
    /// `None`: no exit status (killed by a signal, or the guest command could not be waited for).
    pub exit_code: Option<i32>,
    /// The helper stopped the guest command at its timeout.
    pub timed_out: bool,
    /// The helper stopped the attempt, before or during a step, for the runner's cancel marker.
    #[serde(default)]
    pub cancelled: bool,
    /// `container@<slot>` was active when the command ended; a guest that went away leaves the outcome unknown.
    pub container_active: bool,
    pub stdout_tail: String,
    pub stderr_tail: String,
    pub prepare_ms: u64,
    pub run_ms: u64,
}

impl ExecResult {
    /// # Errors
    /// What [`parse_versioned`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        parse_versioned(json)
    }
}

/// Where the attempt `attempt` at `epoch` settles after its run.
///
/// A run the helper stopped for a cancel is `cancelled`, whatever stage it reached. Otherwise only a run that never
/// started the task's argv goes back to `queued`. No result (or someone else's), a timeout or
/// a guest that went away is `needs_review`, never replayed; otherwise [`agent::outcome`] of the exit and `stdout`
/// (the task's whole captured stdout: Claude's verdict is its last line) decides.
#[must_use]
pub fn decide(
    attempt: &str,
    epoch: u64,
    agent: Agent,
    result: Option<&ExecResult>,
    stdout: &str,
) -> Settle {
    let Some(r) = result.filter(|r| r.attempt_id == attempt && r.lease_epoch == epoch) else {
        return Settle::NeedsReview;
    };
    if r.cancelled {
        return Settle::Cancelled;
    }
    if r.stage == Stage::Prepare {
        return Settle::Queued;
    }
    if r.timed_out || !r.container_active {
        return Settle::NeedsReview;
    }
    match agent::outcome(agent, r.exit_code, stdout) {
        Outcome::Succeeded => Settle::Succeeded,
        Outcome::Failed => Settle::Failed,
        Outcome::NeedsReview => Settle::NeedsReview,
    }
}

/// The receipt a terminal settle carries; a fixture with no agent reports no effect. `None` for a settle that takes
/// none.
#[must_use]
pub fn receipt(task_id: &str, attempt_id: &str, lease_epoch: u64, to: Settle) -> Option<Receipt> {
    let outcome = match to {
        Settle::Succeeded => Outcome::Succeeded,
        Settle::Failed => Outcome::Failed,
        Settle::NeedsReview => Outcome::NeedsReview,
        Settle::Waiting | Settle::Queued | Settle::Cancelled => return None,
    };
    Some(Receipt {
        schema_version: SchemaVersion::CURRENT,
        task_id: task_id.to_owned(),
        attempt_id: attempt_id.to_owned(),
        lease_epoch,
        outcome,
        effects: Vec::new(),
        checkpoint: None,
    })
}

/// Whether a claim at `now` (unix seconds) that holds the slot up to `hold_secs` ends before the host's poweroff.
///
/// `show` is `systemctl show -p LoadState -p NextElapseUSecRealtime --timestamp=unix` of its off timer: a claim the
/// poweroff would cut short sends its attempt to review. A timer with no next elapse is stopped, as a switch restarting
/// it leaves it for a moment: that claims nothing either.
///
/// # Errors
/// A timer that is not loaded, or output this does not read: the runner claims nothing then.
pub fn claim_fits(now: u64, hold_secs: u32, show: &str) -> Result<bool, String> {
    let field = |k: &str| {
        show.lines()
            .find_map(|l| l.strip_prefix(k)?.strip_prefix('='))
    };
    if field("LoadState") != Some("loaded") {
        return Err(format!("off timer not loaded: {show:?}"));
    }
    match field("NextElapseUSecRealtime") {
        Some(next) => next
            .strip_prefix('@')
            .and_then(|n| n.parse::<u64>().ok())
            .map(|off| now.saturating_add(u64::from(hold_secs)) <= off)
            .ok_or_else(|| format!("off timer's next elapse unread: {next:?}")),
        None => Err(format!("off timer's next elapse missing: {show:?}")),
    }
}

/// The last [`TAIL_BYTES`] of `bytes`, lossy UTF-8.
#[must_use]
pub fn tail(bytes: &[u8]) -> String {
    let from = bytes.len().saturating_sub(TAIL_BYTES);
    String::from_utf8_lossy(bytes.get(from..).unwrap_or_default()).into_owned()
}

/// Reads `path` only if it is a regular file, not a symlink, and is still the file that was checked when opened:
/// root reads the manifest from a directory the runner's user owns.
///
/// # Errors
/// Anything else, or a file larger than the read limit.
pub fn read_regular(path: &Path) -> io::Result<String> {
    let before = std::fs::symlink_metadata(path)?;
    if !before.file_type().is_file() {
        return Err(io::Error::other(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    let file = File::open(path)?;
    let opened = file.metadata()?;
    if (opened.dev(), opened.ino()) != (before.dev(), before.ino()) {
        return Err(io::Error::other(format!(
            "{} changed while opened",
            path.display()
        )));
    }
    let mut s = String::new();
    file.take(READ_LIMIT.saturating_add(1))
        .read_to_string(&mut s)?;
    if u64::try_from(s.len()).map_or(true, |n| n > READ_LIMIT) {
        return Err(io::Error::other(format!(
            "{} is over {READ_LIMIT} bytes",
            path.display()
        )));
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn task() -> serde_json::Value {
        json!({
            "schema_version": 1, "id": "t1", "idempotency_key": "k1",
            "source": { "repo": "https://example.org/r.git", "rev": "abc123" },
            "command": { "agent": "none", "argv": ["cargo", "test", "--offline"], "workdir": "crates/x" },
            "capabilities": ["rust"], "resource_class": "small", "credential_class": "none",
            "retry": { "max_attempts": 2 }
        })
    }

    fn manifest(task: &serde_json::Value) -> Result<Manifest, Error> {
        Manifest::parse(
            &json!({ "schema_version": 1, "slot": "pool1", "attempt_id": "t1.a", "lease_epoch": 3, "task": task })
                .to_string(),
        )
    }

    #[test]
    fn a_claim_fits_only_a_lease_that_ends_before_the_poweroff() {
        let show = |next: &str| format!("LoadState=loaded\nNextElapseUSecRealtime={next}\n");
        // 20:10 and a 50-minute lease against 21:00
        let off = 1_764_014_400;
        assert_eq!(
            claim_fits(off - 3000, 3000, &show(&format!("@{off}"))),
            Ok(true)
        );
        assert_eq!(
            claim_fits(off - 2999, 3000, &show(&format!("@{off}"))),
            Ok(false)
        );
        for bad in [
            "LoadState=not-found\nNextElapseUSecRealtime=\n".to_owned(),
            show(""),
            show("Tue 2026-11-24 21:00:00 CET"),
            "LoadState=loaded\n".to_owned(),
            String::new(),
        ] {
            assert!(claim_fits(0, 3000, &bad).is_err(), "{bad:?}");
        }
    }

    fn d(attempt: &str, epoch: u64, r: Option<&ExecResult>) -> Settle {
        decide(attempt, epoch, Agent::None, r, "")
    }

    fn result(stage: Stage, exit_code: Option<i32>) -> ExecResult {
        ExecResult {
            schema_version: SchemaVersion::CURRENT,
            attempt_id: "t1.a".to_owned(),
            lease_epoch: 3,
            stage,
            exit_code,
            timed_out: false,
            cancelled: false,
            container_active: true,
            stdout_tail: String::new(),
            stderr_tail: String::new(),
            prepare_ms: 1,
            run_ms: 1,
        }
    }

    #[test]
    fn manifest_round_trips_and_names_its_directory_safely() {
        let m = manifest(&task()).unwrap();
        assert_eq!(
            Manifest::parse(&serde_json::to_string(&m).unwrap()).unwrap(),
            m
        );
        assert_eq!(m.run_dir(), "74312e61-3");
        let odd = Manifest {
            attempt_id: "../x/y".to_owned(),
            ..m
        };
        assert!(!odd.run_dir().contains('/') && !odd.run_dir().contains(".."));
    }

    #[test]
    fn manifest_refuses_another_version_an_unknown_field_and_an_option_for_a_rev() {
        let mut bad = task();
        bad["source"]["rev"] = json!("--upload-pack=x");
        assert!(manifest(&bad).is_err());
        let mut extra = task();
        extra["token"] = json!("secret");
        assert!(manifest(&extra).is_err());
        let v2 = json!({ "schema_version": 2, "slot": "pool1", "attempt_id": "a", "lease_epoch": 1, "task": task() });
        assert_eq!(
            Manifest::parse(&v2.to_string()),
            Err(Error::SchemaVersion(2))
        );
    }

    fn steps(m: &Manifest) -> [(Stage, Vec<String>); 5] {
        let ws = m.workspace("/home/u").unwrap();
        m.steps(&ws, "/git", "/env", "/mkdir").unwrap()
    }

    #[test]
    fn steps_make_the_workspace_then_clone_and_run_in_it() {
        let m = manifest(&task()).unwrap();
        let [(s1, root), (s2, _), (s3, clone), (s4, checkout), (s5, run)] = steps(&m);
        assert_eq!(
            [s1, s2, s3, s4, s5],
            [
                Stage::Prepare,
                Stage::Prepare,
                Stage::Prepare,
                Stage::Prepare,
                Stage::Run
            ]
        );
        assert_eq!(root, ["/mkdir", "-m", "0700", "--", "/home/u/attempts"]);
        let dir = "/home/u/attempts/74312e61-3";
        let git = [
            "/env",
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_CONFIG_NOSYSTEM=1",
            "/git",
        ];
        assert_eq!(clone[..4], git, "no rewrite to ssh from the guest's config");
        assert_eq!(checkout[..4], git);
        assert_eq!(
            clone[4..],
            [
                "clone",
                "--quiet",
                "--",
                "https://example.org/r.git",
                &format!("{dir}/work")
            ]
        );
        assert_eq!(
            checkout[4..],
            [
                "-C",
                &format!("{dir}/work"),
                "checkout",
                "--quiet",
                "--detach",
                "abc123"
            ]
        );
        assert_eq!(
            run,
            [
                "/env",
                "-C",
                &format!("{dir}/work/crates/x"),
                "--",
                &format!("HOME={dir}/home"),
                &format!("TMPDIR={dir}/tmp"),
                "cargo",
                "test",
                "--offline"
            ]
        );
    }

    #[test]
    fn only_a_run_that_never_started_the_task_is_queued_again() {
        let ok = result(Stage::Run, Some(0));
        assert_eq!(d("t1.a", 3, Some(&ok)), Settle::Succeeded);
        assert_eq!(
            d("t1.a", 3, Some(&result(Stage::Run, Some(1)))),
            Settle::Failed
        );
        assert_eq!(
            d("t1.a", 3, Some(&result(Stage::Prepare, Some(128)))),
            Settle::Queued
        );
        assert_eq!(
            d("t1.a", 3, Some(&result(Stage::Prepare, None))),
            Settle::Queued
        );
    }

    #[test]
    fn an_unknown_end_goes_to_review() {
        let ok = result(Stage::Run, Some(0));
        assert_eq!(d("t1.a", 3, None), Settle::NeedsReview);
        assert_eq!(
            d("t1.a", 2, Some(&ok)),
            Settle::NeedsReview,
            "another epoch's result"
        );
        assert_eq!(
            d("t2.a", 3, Some(&ok)),
            Settle::NeedsReview,
            "another attempt's result"
        );
        assert_eq!(
            d("t1.a", 3, Some(&result(Stage::Run, None))),
            Settle::NeedsReview
        );
        let timed_out = ExecResult {
            timed_out: true,
            ..ok.clone()
        };
        assert_eq!(d("t1.a", 3, Some(&timed_out)), Settle::NeedsReview);
        let gone = ExecResult {
            container_active: false,
            exit_code: Some(1),
            ..ok
        };
        assert_eq!(d("t1.a", 3, Some(&gone)), Settle::NeedsReview);
    }

    #[test]
    fn a_cancelled_run_settles_cancelled_at_any_stage_but_only_its_own() {
        for stage in [Stage::Prepare, Stage::Run] {
            let stopped = ExecResult {
                cancelled: true,
                ..result(stage, None)
            };
            assert_eq!(d("t1.a", 3, Some(&stopped)), Settle::Cancelled);
            assert_eq!(d("t1.a", 2, Some(&stopped)), Settle::NeedsReview);
        }
        assert_eq!(receipt("t1", "t1.a", 3, Settle::Cancelled), None);
    }

    #[test]
    fn an_agent_run_settles_by_the_adapter() {
        let ok = result(Stage::Run, Some(0));
        let claude = |stdout| decide("t1.a", 3, Agent::Claude, Some(&ok), stdout);
        assert_eq!(claude("{\"is_error\":false}\n"), Settle::Succeeded);
        assert_eq!(claude("{\"is_error\":true}\n"), Settle::Failed);
        assert_eq!(
            claude(""),
            Settle::NeedsReview,
            "a Claude run with no result"
        );
        let mut t = task();
        t["command"] = json!({ "agent": "claude", "argv": ["fix it"], "workdir": "." });
        let [.., (_, run)] = steps(&manifest(&t).unwrap());
        assert_eq!(run[2], "/home/u/attempts/74312e61-3/work/.");
        assert_eq!(
            run[6..],
            agent::argv(&manifest(&t).unwrap().task).unwrap()[..]
        );
        t["command"]["argv"] = json!(["a", "b", "c"]);
        assert!(manifest(&t).is_err(), "an agent argv the adapter refuses");
    }

    #[test]
    fn a_terminal_settle_carries_a_receipt_that_settles_it() {
        assert!(receipt("t1", "t1.a", 3, Settle::Queued).is_none());
        let r = receipt("t1", "t1.a", 3, Settle::Failed).unwrap();
        assert_eq!(
            (r.outcome, r.effects.len(), r.lease_epoch),
            (Outcome::Failed, 0, 3)
        );
        assert!(Receipt::parse(&serde_json::to_string(&r).unwrap()).is_ok());
    }

    #[test]
    fn a_signal_from_the_guest_is_no_exit() {
        assert_eq!(guest_exit(Some(0)), Some(0));
        assert_eq!(guest_exit(Some(3)), Some(3));
        assert_eq!(guest_exit(Some(255)), None);
        assert_eq!(guest_exit(None), None);
    }

    #[test]
    fn tail_keeps_the_end() {
        let long = vec![b'x'; TAIL_BYTES + 10];
        assert_eq!(tail(&long).len(), TAIL_BYTES);
        assert_eq!(tail(b"short"), "short");
    }

    #[test]
    fn read_regular_refuses_a_symlink() {
        let dir = std::env::temp_dir().join(format!("exec-pool-runner-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("m.json");
        std::fs::write(&file, "{}").unwrap();
        let link = dir.join("link.json");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert_eq!(read_regular(&file).unwrap(), "{}");
        assert!(read_regular(&link).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
