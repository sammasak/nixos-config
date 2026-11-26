//! `exec-pool-runner drain-wait`, a deploy's wait on the slots' helpers, against a stand-in `systemctl` on PATH that
//! lists the units a test names and a runtime directory holding their manifests.

#![allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "the fixture's helpers: a failure there is the test failing"
)]

use std::fmt::Write as _;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use serde_json::json;

struct Host {
    dir: PathBuf,
}

impl Host {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("exec-pool-drain-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::create_dir_all(dir.join("run")).unwrap();
        let systemctl = dir.join("bin/systemctl");
        fs::write(&systemctl, "#!/bin/sh\ncat \"$UNITS\"\n").unwrap();
        fs::set_permissions(&systemctl, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(dir.join("units"), "").unwrap();
        Self { dir }
    }

    /// A helper running on `slot` for task `id`, a session turn's or a one-shot run's.
    fn running(&self, slot: &str, id: &str, session: bool) {
        let mut task = json!({
            "schema_version": 1, "id": id, "idempotency_key": id,
            "source": { "repo": "https://example.org/r.git", "rev": "abc123" },
            "command": { "agent": "none", "argv": ["true"], "workdir": "." },
            "capabilities": [], "resource_class": "small", "credential_class": "none",
            "retry": { "max_attempts": 2 }
        });
        let mut manifest = json!({ "schema_version": 1, "slot": slot, "attempt_id": format!("{id}.a"), "lease_epoch": 1 });
        if session {
            task["command"] =
                json!({ "agent": "claude", "argv": ["fix it", "opus"], "workdir": "." });
            manifest["session"] =
                json!({ "uuid": "a3a7c578-9125-8a32-a933-73a095d4a27b", "input": "go", "upto": 1 });
        }
        manifest["task"] = task;
        fs::create_dir_all(self.dir.join("run").join(slot)).unwrap();
        fs::write(
            self.dir.join("run").join(slot).join("manifest.json"),
            manifest.to_string(),
        )
        .unwrap();
        let mut units = fs::read_to_string(self.dir.join("units")).unwrap();
        writeln!(
            units,
            "exec-pool-exec@{slot}.service loaded activating start Run the attempt"
        )
        .unwrap();
        fs::write(self.dir.join("units"), units).unwrap();
    }

    fn wait(&self, secs: u64, one_shot_secs: u64) -> (Output, Duration) {
        let t = Instant::now();
        let path = format!(
            "{}:{}",
            self.dir.join("bin").display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let out = Command::new(env!("CARGO_BIN_EXE_exec-pool-runner"))
            .args(["drain-wait", &self.dir.join("run").display().to_string()])
            .args([secs.to_string(), one_shot_secs.to_string()])
            .env("PATH", path)
            .env("UNITS", self.dir.join("units"))
            .output()
            .unwrap();
        (out, t.elapsed())
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn a_running_one_shot_run_is_waited_on_only_its_bound_named_then_left_to_finish() {
    let host = Host::new("one-shot");
    host.running("pool3", "cli-04c024ce39380737", false);
    let (out, took) = host.wait(900, 2);
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(0), "{err}");
    assert!(
        took < Duration::from_secs(60),
        "waited {took:?} of the 900 s bound: {err}"
    );
    let first = err.lines().next().unwrap_or_default();
    assert!(
        first.starts_with("exec-pool-drain: waited 0s of 900s")
            && first.contains("pool3 task cli-04c024ce39380737 (one-shot, running "),
        "{err}"
    );
    let last = err.lines().last().unwrap_or_default();
    assert!(
        last.contains("leaving pool3 task cli-04c024ce39380737 (one-shot, running ")
            && last.contains("to finish under the new generation"),
        "{err}"
    );
}

#[test]
fn a_running_session_turn_is_waited_on_to_the_bound_and_named_when_it_expires() {
    let host = Host::new("session");
    host.running("pool1", "cli-session", true);
    host.running("pool3", "cli-one-shot", false);
    let (out, _) = host.wait(3, 1);
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    let last = err.lines().last().unwrap_or_default();
    assert!(
        last.contains("still running after ")
            && last.contains("pool1 task cli-session (session turn, running ")
            && last.contains("pool3 task cli-one-shot (one-shot, running "),
        "{err}"
    );
}

#[test]
fn an_unreadable_manifest_is_waited_on_as_a_session_turn_and_no_helper_returns_at_once() {
    let host = Host::new("unknown");
    let (out, took) = host.wait(3, 0);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert!(
        stderr(&out).is_empty() && took < Duration::from_secs(3),
        "{}",
        stderr(&out)
    );
    fs::write(
        host.dir.join("units"),
        "exec-pool-exec@pool2.service loaded active running x\n",
    )
    .unwrap();
    let (out, _) = host.wait(3, 0);
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert!(
        err.contains("pool2 task unknown (no readable manifest)"),
        "{err}"
    );
    assert!(!Path::new(&host.dir.join("run/pool2")).exists());
}

#[test]
fn a_long_wait_says_what_it_waits_on_every_30_s() {
    let host = Host::new("cadence");
    host.running("pool1", "cli-session", true);
    let (out, _) = host.wait(34, 0);
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    let said: Vec<&str> = err
        .lines()
        .filter(|l| l.starts_with("exec-pool-drain: waited "))
        .collect();
    assert!(
        said.len() == 2
            && said[1].starts_with("exec-pool-drain: waited 30s of 34s")
            && said[1].contains("pool1 task cli-session"),
        "{err}"
    );
}
