//! `exec-pool-runner`: the pool runner (#652) for one slot, and its slot-control helper.
//!
//! `run` (the queue's peer role, from `exec-pool-runner@<slot>.service`) loops: reconcile, claim an attempt for the
//! slot, accept `start`, write the manifest, start `exec-pool-exec@<slot>`, then checkpoint and settle from its
//! result, and release the slot with `dev-env-reset@<slot>`. It begins no work before `start` is accepted, and never
//! re-sends an event whose outcome is unknown: the lease expires and `reconcile` decides. A reset that fails
//! quarantines the slot until an operator removes the marker. Each state change is one JSON line on stdout.
//!
//! `exec SLOT` (root, from `exec-pool-exec@<slot>.service`) reads the manifest, admits the attempt only to a slot home
//! reset since the last one ran, runs the task's steps in the guest as its user with `systemd-run -M` in the attempt's
//! workspace, keeps the output under its state directory and writes the result there. It holds no queue access.

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use exec_pool::queue::{Change, Claim, QueueError, Store};
use exec_pool::runner::{
    CAPTURE_BYTES, ExecResult, Manifest, Stage, decide, guest_exit, read_regular, receipt, tail,
};
use exec_pool::workspace::{HomeId, admit};
use exec_pool::{Event, Kind, Receipt, SchemaVersion, Slot};
use serde_json::{Value, json};

const USAGE: &str =
    "usage: exec-pool-runner run | exec SLOT   (configured by the environment its unit sets)";
const MANIFEST: &str = "manifest.json";
const RESULT: &str = "result.json";
/// The slot home the last admitted attempt ran in, beside the slot's run directories.
const LAST_HOME: &str = "home.json";
const POLL: Duration = Duration::from_secs(10);
const BACKOFF: Duration = Duration::from_secs(30);
const PREPARE_TIMEOUT: Duration = Duration::from_secs(300);
const RESET_TRIES: u32 = 3;

fn var(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("{name} is not set"))
}

fn line(v: &Value) {
    println!("{v}");
}

fn log_change(c: &Change) {
    line(&json!({ "msg": "state_change", "change": c }));
}

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// `systemctl start` as the runner's user: the polkit rule admits exactly this slot's two units.
fn start_unit(unit: &str) -> Result<(), String> {
    let out = Command::new("systemctl")
        .args(["start", unit])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("systemctl: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "systemctl start {unit}: {} {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

struct Runner {
    slot: Slot,
    lease_secs: u32,
    runtime: PathBuf,
    exec_dir: PathBuf,
    quarantine: PathBuf,
}

impl Runner {
    fn from_env() -> Result<Self, String> {
        let slot =
            Slot::parse(&var("EXEC_POOL_SLOT")?).map_err(|e| format!("EXEC_POOL_SLOT: {e}"))?;
        let quarantine =
            PathBuf::from(var("EXEC_POOL_STATE")?).join(format!("{}.quarantined", slot.id));
        Ok(Self {
            lease_secs: var("EXEC_POOL_LEASE_SECS")?
                .parse()
                .map_err(|_| "EXEC_POOL_LEASE_SECS must be a number".to_owned())?,
            runtime: PathBuf::from(var("EXEC_POOL_RUNTIME")?),
            exec_dir: PathBuf::from(var("EXEC_POOL_EXEC_DIR")?).join(&slot.id),
            quarantine,
            slot,
        })
    }

    fn error(&self, at: &str, e: &dyn std::fmt::Display) {
        line(&json!({ "msg": "error", "slot": self.slot.id, "at": at, "error": e.to_string() }));
    }

    fn guest_up(&self) -> bool {
        Command::new("systemctl")
            .args([
                "is-active",
                "--quiet",
                &format!("container@{}.service", self.slot.id),
            ])
            .status()
            .is_ok_and(|s| s.success())
    }

    /// The slot back to a fresh home, or quarantined: a reset refuses a running agent or unpushed work, and a slot
    /// it could not reset is not offered again.
    fn release(&self) -> bool {
        let t = Instant::now();
        let unit = format!("dev-env-reset@{}.service", self.slot.id);
        let mut last = String::new();
        for _ in 0..RESET_TRIES {
            match start_unit(&unit) {
                Ok(()) => {
                    line(
                        &json!({ "msg": "slot_reset", "slot": self.slot.id, "sanitize_ms": ms(t) }),
                    );
                    return true;
                }
                Err(e) => last = e,
            }
            thread::sleep(BACKOFF);
        }
        let _ = fs::write(&self.quarantine, format!("{last}\n"));
        line(
            &json!({ "msg": "slot_quarantined", "slot": self.slot.id, "reason": last,
                      "release": format!("rm {} and restart the runner", self.quarantine.display()) }),
        );
        false
    }

    fn loop_forever(&self, store: &mut Store) -> ! {
        // the slot's state at startup is unknown: a runner that died mid-run left it as it was
        let mut dirty = true;
        loop {
            // a guest down or restarting (a switch restarts it) is waited for, not a reset that fails
            if self.quarantine.exists() || (dirty && (!self.guest_up() || !self.release())) {
                thread::sleep(BACKOFF);
                continue;
            }
            dirty = false;
            match store.reconcile() {
                Ok(changes) => changes.iter().for_each(log_change),
                Err(e) => {
                    self.error("reconcile", &e);
                    thread::sleep(BACKOFF);
                    continue;
                }
            }
            match store.claim(&self.slot, self.lease_secs) {
                Ok(Some(claim)) => {
                    log_change(&claim.change);
                    dirty = self.attempt(store, &claim);
                }
                Ok(None) => thread::sleep(POLL),
                // an unknown claim is left to expire: leased and never started, it goes back to queued
                Err(e) => {
                    self.error("claim", &e);
                    thread::sleep(BACKOFF);
                }
            }
        }
    }

    fn event(
        store: &mut Store,
        attempt: &str,
        epoch: u64,
        kind: Kind,
        r: Option<&Receipt>,
    ) -> Result<(), QueueError> {
        let (_, change) = store.apply(attempt, &Event { epoch, kind }, r)?;
        log_change(&change);
        Ok(())
    }

    /// One claimed attempt; whether the slot ran anything and needs a reset.
    fn attempt(&self, store: &mut Store, claim: &Claim) -> bool {
        let claimed = Instant::now();
        let (id, epoch) = (claim.attempt.id.as_str(), claim.attempt.lease_epoch);
        let manifest = Manifest {
            schema_version: SchemaVersion::CURRENT,
            slot: self.slot.id.clone(),
            attempt_id: id.to_owned(),
            lease_epoch: epoch,
            task: claim.task.clone(),
        };
        let written = serde_json::to_string(&manifest)
            .map_err(io::Error::other)
            .and_then(|json| {
                let tmp = self.runtime.join(format!("{MANIFEST}.tmp"));
                fs::write(&tmp, json)?;
                fs::rename(&tmp, self.runtime.join(MANIFEST))
            });
        if let Err(e) = written {
            self.error("manifest", &e);
            return false;
        }
        if let Err(e) = Self::event(store, id, epoch, Kind::Start, None) {
            self.error("start", &e);
            return false;
        }
        let claim_to_exec_ms = ms(claimed);
        let exec = Instant::now();
        if let Err(e) = start_unit(&format!("exec-pool-exec@{}.service", self.slot.id)) {
            self.error("exec", &e);
        }
        let exec_ms = ms(exec);
        let dir = self.exec_dir.join(manifest.run_dir());
        let result = read_regular(&dir.join(RESULT))
            .map_err(|e| e.to_string())
            .and_then(|s| ExecResult::parse(&s).map_err(|e| e.to_string()))
            .inspect_err(|e| self.error("result", e))
            .ok();
        let stdout = String::from_utf8_lossy(&read_capture(&dir.join("stdout"))).into_owned();
        let to = decide(
            id,
            epoch,
            claim.task.command.agent,
            result.as_ref(),
            &stdout,
        );
        let settled = Self::event(store, id, epoch, Kind::Checkpoint, None).and_then(|()| {
            let r = receipt(&claim.task.id, id, epoch, to);
            Self::event(store, id, epoch, Kind::Settle(to), r.as_ref())
        });
        if let Err(e) = &settled {
            self.error("settle", e);
        }
        line(&json!({
            "msg": "run", "task_id": claim.task.id, "attempt": id, "lease_epoch": epoch, "slot": self.slot.id,
            "settle": format!("{to:?}"), "settled": settled.is_ok(), "output": dir,
            "exit_code": result.as_ref().and_then(|r| r.exit_code),
            "timed_out": result.as_ref().map(|r| r.timed_out),
            "stdout_tail": result.as_ref().map(|r| r.stdout_tail.as_str()),
            "stderr_tail": result.as_ref().map(|r| r.stderr_tail.as_str()),
            "claim_to_exec_ms": claim_to_exec_ms, "exec_ms": exec_ms,
            "prepare_ms": result.as_ref().map(|r| r.prepare_ms), "run_ms": result.as_ref().map(|r| r.run_ms),
        }));
        true
    }
}

fn run() -> Result<(), String> {
    let runner = Runner::from_env()?;
    let mut store = Store::open(&var("EXEC_POOL_DB")?).map_err(|e| e.to_string())?;
    runner.loop_forever(&mut store)
}

struct Guest {
    slot: String,
    user: String,
    /// `K=V` for each step: the slot's agent route and a PATH that finds the agent.
    env: Vec<String>,
}

struct StepEnd {
    exit_code: Option<i32>,
    timed_out: bool,
}

impl Guest {
    /// Copies at most [`CAPTURE_BYTES`] of `from` into `to` and drains the rest, so a chatty task cannot fill the host.
    fn capture(
        from: impl io::Read + Send + 'static,
        to: &File,
    ) -> io::Result<thread::JoinHandle<io::Result<()>>> {
        let mut to = to.try_clone()?;
        Ok(thread::spawn(move || {
            let mut from = from;
            io::copy(&mut (&mut from).take(CAPTURE_BYTES), &mut to)?;
            io::copy(&mut from, &mut io::sink())?;
            Ok(())
        }))
    }

    /// One command in the guest as its user, in its home, as a transient unit the helper stops at `timeout`.
    fn step(
        &self,
        unit: &str,
        argv: &[String],
        timeout: Duration,
        out: &File,
        err: &File,
    ) -> io::Result<StepEnd> {
        let mut child: Child = Command::new("systemd-run")
            .args([
                "-M",
                &self.slot,
                &format!("--uid={}", self.user),
                // systemd would otherwise substitute `$X` and `${X}` in the task's argv
                "--expand-environment=no",
                "--wait",
                "--pipe",
                "--quiet",
                "--collect",
                "--service-type=oneshot",
            ])
            .args([
                &format!("--unit={unit}"),
                "-p",
                "WorkingDirectory=~",
                "-E",
                "GIT_TERMINAL_PROMPT=0",
            ])
            .args(self.env.iter().flat_map(|e| ["-E", e]))
            .arg("--")
            .args(argv)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let readers = [
            child
                .stdout
                .take()
                .map(|s| Self::capture(s, out))
                .transpose()?,
            child
                .stderr
                .take()
                .map(|s| Self::capture(s, err))
                .transpose()?,
        ];
        let t = Instant::now();
        let mut timed_out = false;
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if !timed_out && t.elapsed() > timeout {
                timed_out = true;
                let _ = Command::new("systemctl")
                    .args(["-M", &self.slot, "stop", unit])
                    .status();
            }
            thread::sleep(Duration::from_millis(200));
        };
        for r in readers.into_iter().flatten() {
            r.join()
                .map_err(|_| io::Error::other("a capture thread panicked"))??;
        }
        Ok(StepEnd {
            exit_code: guest_exit(status.code()),
            timed_out,
        })
    }

    /// Runs `steps` in order until one fails or times out, recording in `result` where it stopped.
    fn steps(
        &self,
        steps: [(Stage, Vec<String>); 5],
        timeout: Duration,
        (out, err): (&File, &File),
        result: &mut ExecResult,
    ) {
        let t = Instant::now();
        let units = [
            "exec-pool-root",
            "exec-pool-workspace",
            "exec-pool-clone",
            "exec-pool-checkout",
            "exec-pool-task",
        ];
        for ((stage, argv), unit) in steps.into_iter().zip(units) {
            if stage == Stage::Run {
                result.prepare_ms = ms(t);
            }
            result.stage = stage;
            let limit = match stage {
                Stage::Prepare => PREPARE_TIMEOUT,
                Stage::Run => timeout,
            };
            let started = Instant::now();
            let end = self
                .step(unit, &argv, limit, out, err)
                .map_err(|e| format!("{unit}: {e}"));
            let end = end.unwrap_or_else(|e| {
                let _ =
                    io::Write::write_all(&mut &*err, format!("exec-pool-exec: {e}\n").as_bytes());
                StepEnd {
                    exit_code: None,
                    timed_out: false,
                }
            });
            if stage == Stage::Run {
                result.run_ms = ms(started);
            }
            result.exit_code = end.exit_code;
            result.timed_out = end.timed_out;
            if end.exit_code != Some(0) || end.timed_out {
                break;
            }
        }
    }
}

/// What a stream's capture holds, empty if it cannot be read.
fn read_capture(path: &Path) -> Vec<u8> {
    let mut buf = Vec::new();
    let _ = File::open(path).and_then(|f| f.take(CAPTURE_BYTES).read_to_end(&mut buf));
    buf
}

/// Admits an attempt to the slot home at `home` if it is not the one recorded in `seen`, and records it there.
fn admit_home(home: &Path, seen: &Path) -> Result<(), String> {
    let now = HomeId::of(home).map_err(|e| format!("{}: {e}", home.display()))?;
    let last = match read_regular(seen) {
        Ok(s) => Some(serde_json::from_str::<HomeId>(&s).map_err(|e| format!("{LAST_HOME}: {e}"))?),
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("{LAST_HOME}: {e}")),
    };
    admit(last, now).map_err(|e| e.to_string())?;
    let tmp = seen.with_extension("tmp");
    serde_json::to_string(&now)
        .map_err(io::Error::other)
        .and_then(|json| fs::write(&tmp, json))
        .and_then(|()| fs::rename(&tmp, seen))
        .map_err(|e| format!("{LAST_HOME}: {e}"))
}

fn exec(slot: &str) -> Result<(), String> {
    let path = PathBuf::from(var("EXEC_POOL_RUNTIME")?).join(MANIFEST);
    let manifest = read_regular(&path)
        .map_err(|e| format!("{}: {e}", path.display()))
        .and_then(|s| Manifest::parse(&s).map_err(|e| format!("manifest: {e}")))?;
    if manifest.slot != slot {
        return Err(format!("the manifest is for {}, not {slot}", manifest.slot));
    }
    let timeout = Duration::from_secs(
        var("EXEC_POOL_TIMEOUT_SECS")?
            .parse()
            .map_err(|_| "EXEC_POOL_TIMEOUT_SECS must be a number".to_owned())?,
    );
    let slot_dir = PathBuf::from(var("EXEC_POOL_EXEC_DIR")?).join(slot);
    let dir = slot_dir.join(manifest.run_dir());
    // create_dir, not _all: a directory already there is this attempt run once already (a restarted helper), not
    // to be run again
    dir.parent()
        .map_or(Ok(()), fs::create_dir_all)
        .and_then(|()| fs::create_dir(&dir))
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    let open = |name: &str| File::create(dir.join(name)).map_err(|e| format!("{name}: {e}"));
    let (out, err) = (open("stdout")?, open("stderr")?);
    let env: BTreeMap<String, String> = serde_json::from_str(&var("EXEC_POOL_AGENT_ENV")?)
        .map_err(|e| format!("EXEC_POOL_AGENT_ENV: {e}"))?;
    let guest = Guest {
        slot: slot.to_owned(),
        user: var("EXEC_POOL_GUEST_USER")?,
        env: env.iter().map(|(k, v)| format!("{k}={v}")).collect(),
    };
    let mut result = ExecResult {
        schema_version: SchemaVersion::CURRENT,
        attempt_id: manifest.attempt_id.clone(),
        lease_epoch: manifest.lease_epoch,
        stage: Stage::Prepare,
        exit_code: None,
        timed_out: false,
        container_active: true,
        stdout_tail: String::new(),
        stderr_tail: String::new(),
        prepare_ms: 0,
        run_ms: 0,
    };
    let t = Instant::now();
    let ws = manifest
        .workspace(&var("EXEC_POOL_GUEST_HOME")?)
        .map_err(|e| format!("manifest: {e}"))?;
    let steps = manifest
        .steps(
            &ws,
            &var("EXEC_POOL_GIT")?,
            &var("EXEC_POOL_ENV")?,
            &var("EXEC_POOL_MKDIR")?,
        )
        .map_err(|e| format!("manifest: {e}"))?;
    // a home an earlier attempt ran in is refused before anything runs in it: the attempt goes back to the queue
    let admitted = admit_home(
        &PathBuf::from(var("EXEC_POOL_SLOT_HOME")?),
        &slot_dir.join(LAST_HOME),
    )
    .inspect_err(|e| {
        let _ = io::Write::write_all(
            &mut &err,
            format!("exec-pool-exec: not admitted: {e}\n").as_bytes(),
        );
    })
    .is_ok();
    if admitted {
        guest.steps(steps, timeout, (&out, &err), &mut result);
    }
    if result.stage == Stage::Prepare {
        result.prepare_ms = ms(t);
    }
    result.container_active = Command::new("systemctl")
        .args(["is-active", "--quiet", &format!("container@{slot}.service")])
        .status()
        .is_ok_and(|s| s.success());
    result.stdout_tail = tail(&read_capture(&dir.join("stdout")));
    result.stderr_tail = tail(&read_capture(&dir.join("stderr")));
    let json = serde_json::to_string(&result).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("{RESULT}.tmp"));
    fs::write(&tmp, json)
        .and_then(|()| fs::rename(&tmp, dir.join(RESULT)))
        .map_err(|e| format!("{RESULT}: {e}"))
}

fn main() -> ExitCode {
    let cli: Vec<String> = std::env::args().skip(1).collect();
    let outcome = match cli
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["run"] => run(),
        ["exec", slot] => exec(slot),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("exec-pool-runner: {e}");
            ExitCode::FAILURE
        }
    }
}
