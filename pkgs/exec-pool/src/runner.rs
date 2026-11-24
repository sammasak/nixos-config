//! What the pool runner (#652) and its slot-control helper agree on, and the runner's decisions.
//!
//! Apart from the host, so they are tested without one. The runner (`exec_pool`, the queue's peer role) claims an attempt, writes a
//! [`Manifest`] and starts `exec-pool-exec@<slot>`; that helper (root, no queue access) runs the task in the slot's
//! guest as its user and writes an [`ExecResult`]; the runner settles the attempt from it with [`decide`] and releases
//! the slot with `dev-env-reset@<slot>`.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Read as _};
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{Error, Outcome, Receipt, SchemaVersion, Settle, TaskSpec, parse_versioned};

/// The task's checkout under the guest user's home; the reset that releases the slot removes it with the home.
pub const CHECKOUT: &str = "task";
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
    /// the grant at submit) rejects, and a `rev` that would read as an option.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let m: Self = parse_versioned(json)?;
        m.task.validate(&m.task.capabilities)?;
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

    /// The guest commands in order: clone, check out, then the task's argv in its workdir. Each is an argv, never a
    /// shell string; `git` and `env` are store paths the guest shares.
    #[must_use]
    pub fn steps(&self, git: &str, env: &str) -> [(Stage, Vec<String>); 3] {
        let s = |v: &[&str]| v.iter().map(|&x| x.to_owned()).collect::<Vec<_>>();
        let t = &self.task;
        let mut run = s(&[
            env,
            "-C",
            &format!("{CHECKOUT}/{}", t.command.workdir.as_str()),
            "--",
        ]);
        run.extend(t.command.argv.iter().cloned());
        [
            (
                Stage::Prepare,
                s(&[
                    git,
                    "clone",
                    "--quiet",
                    "--no-checkout",
                    "--",
                    &t.source.repo,
                    CHECKOUT,
                ]),
            ),
            (
                Stage::Prepare,
                s(&[
                    git,
                    "-C",
                    CHECKOUT,
                    "checkout",
                    "--quiet",
                    "--detach",
                    &t.source.rev,
                ]),
            ),
            (Stage::Run, run),
        ]
    }
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
/// Only a run that never started the task's argv goes
/// back to `queued`; a run whose end is not a plain exit (no result, someone else's, a timeout, a signal, a guest
/// that went away) goes to `needs_review`, never replayed.
#[must_use]
pub fn decide(attempt: &str, epoch: u64, result: Option<&ExecResult>) -> Settle {
    let Some(r) = result.filter(|r| r.attempt_id == attempt && r.lease_epoch == epoch) else {
        return Settle::NeedsReview;
    };
    match (r.stage, r.exit_code) {
        (Stage::Prepare, _) => Settle::Queued,
        _ if r.timed_out || !r.container_active => Settle::NeedsReview,
        (Stage::Run, Some(0)) => Settle::Succeeded,
        (Stage::Run, Some(_)) => Settle::Failed,
        (Stage::Run, None) => Settle::NeedsReview,
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
        Settle::Waiting | Settle::Queued => return None,
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

    fn result(stage: Stage, exit_code: Option<i32>) -> ExecResult {
        ExecResult {
            schema_version: SchemaVersion::CURRENT,
            attempt_id: "t1.a".to_owned(),
            lease_epoch: 3,
            stage,
            exit_code,
            timed_out: false,
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

    #[test]
    fn steps_are_argv_with_the_repo_and_argv_after_a_separator() {
        let m = manifest(&task()).unwrap();
        let [(s1, clone), (s2, checkout), (s3, run)] = m.steps("/git", "/env");
        assert_eq!((s1, s2, s3), (Stage::Prepare, Stage::Prepare, Stage::Run));
        assert_eq!(
            clone,
            [
                "/git",
                "clone",
                "--quiet",
                "--no-checkout",
                "--",
                "https://example.org/r.git",
                "task"
            ]
        );
        assert_eq!(
            checkout,
            [
                "/git", "-C", "task", "checkout", "--quiet", "--detach", "abc123"
            ]
        );
        assert_eq!(
            run,
            [
                "/env",
                "-C",
                "task/crates/x",
                "--",
                "cargo",
                "test",
                "--offline"
            ]
        );
    }

    #[test]
    fn only_a_run_that_never_started_the_task_is_queued_again() {
        let ok = result(Stage::Run, Some(0));
        assert_eq!(decide("t1.a", 3, Some(&ok)), Settle::Succeeded);
        assert_eq!(
            decide("t1.a", 3, Some(&result(Stage::Run, Some(1)))),
            Settle::Failed
        );
        assert_eq!(
            decide("t1.a", 3, Some(&result(Stage::Prepare, Some(128)))),
            Settle::Queued
        );
        assert_eq!(
            decide("t1.a", 3, Some(&result(Stage::Prepare, None))),
            Settle::Queued
        );
    }

    #[test]
    fn an_unknown_end_goes_to_review() {
        let ok = result(Stage::Run, Some(0));
        assert_eq!(decide("t1.a", 3, None), Settle::NeedsReview);
        assert_eq!(
            decide("t1.a", 2, Some(&ok)),
            Settle::NeedsReview,
            "another epoch's result"
        );
        assert_eq!(
            decide("t2.a", 3, Some(&ok)),
            Settle::NeedsReview,
            "another attempt's result"
        );
        assert_eq!(
            decide("t1.a", 3, Some(&result(Stage::Run, None))),
            Settle::NeedsReview
        );
        let timed_out = ExecResult {
            timed_out: true,
            ..ok.clone()
        };
        assert_eq!(decide("t1.a", 3, Some(&timed_out)), Settle::NeedsReview);
        let gone = ExecResult {
            container_active: false,
            exit_code: Some(1),
            ..ok
        };
        assert_eq!(decide("t1.a", 3, Some(&gone)), Settle::NeedsReview);
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
