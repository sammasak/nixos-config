//! `exec-pool-runner`: the pool runner (#652) for one slot, and its slot-control helper.
//!
//! `run` (the queue's peer role, from `exec-pool-runner@<slot>.service`) loops: reconcile, claim an attempt for the
//! slot, accept `start`, write the manifest, start `exec-pool-exec@<slot>`, then checkpoint and settle from its
//! result, record the result, and release the slot with `dev-env-reset@<slot>`. It begins no work before `start` is
//! accepted, and never re-sends an event whose outcome is unknown: the lease expires and `reconcile` decides. While
//! the helper runs it renews the lease every [`HEARTBEAT`]; a cancel the heartbeat reports, or a lease it finds lost,
//! writes the cancel marker the helper stops at. A runner that dies renews nothing, and the lease expires. A reset
//! that fails quarantines the slot until an operator removes the marker. With `EXEC_POOL_OFF_TIMER` it claims only
//! while a claim, held up to `EXEC_POOL_CLAIM_SECS`, ends before that timer powers the host off; with a credentials
//! directory it is a remote slot's runner, reaching the queue over TCP with the `db-password` credential. Each state change is one JSON line on stdout.
//!
//! `exec SLOT` (root, from `exec-pool-exec@<slot>.service`) reads the manifest, admits the attempt only to a slot home
//! reset since the last one ran, runs the task's steps in the guest as its user with `systemd-run -M` in the attempt's
//! workspace, keeps the output under its state directory and writes the result there. It stops the step running, and
//! starts no other, once the runner's cancel marker names the attempt. It holds no queue access.

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, Read as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use exec_pool::queue::{Change, Claim, QueueError, Store};
use exec_pool::runner::{
    CAPTURE_BYTES, ExecResult, Manifest, Stage, claim_fits, decide, guest_exit, read_regular,
    receipt, tail,
};
use exec_pool::task_result::TaskResult;
use exec_pool::workspace::{HomeId, admit};
use exec_pool::{Event, Kind, Receipt, SchemaVersion, Slot};
use serde_json::{Value, json};

const USAGE: &str =
    "usage: exec-pool-runner run | exec SLOT   (configured by the environment its unit sets)";
const MANIFEST: &str = "manifest.json";
const RESULT: &str = "result.json";
/// Beside the manifest: the attempt the helper is to stop, as [`Manifest::cancel_token`].
const CANCEL: &str = "cancel";
/// The slot home the last admitted attempt ran in, beside the slot's run directories.
const LAST_HOME: &str = "home.json";
const POLL: Duration = Duration::from_secs(10);
/// How often the runner renews a lease and reads its cancel mark while the helper runs; the lease must be longer.
const HEARTBEAT: Duration = POLL;
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

/// `systemctl start` of the oneshot helper, which returns once the helper has run, as a child to wait on.
fn spawn_start(unit: &str) -> Result<Child, String> {
    Command::new("systemctl")
        .args(["start", unit])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("systemctl: {e}"))
}

struct Runner {
    slot: Slot,
    lease_secs: u32,
    runtime: PathBuf,
    exec_dir: PathBuf,
    quarantine: PathBuf,
    /// The host's scheduled poweroff timer: a lease must end before it fires.
    /// and the longest a claim holds the slot: its run's bound, then the settle and reset
    off_timer: Option<(String, u32)>,
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
            off_timer: match std::env::var("EXEC_POOL_OFF_TIMER") {
                Ok(timer) => Some((
                    timer,
                    var("EXEC_POOL_CLAIM_SECS")?
                        .parse()
                        .map_err(|_| "EXEC_POOL_CLAIM_SECS must be a number".to_owned())?,
                )),
                Err(_) => None,
            },
            slot,
        })
    }

    fn error(&self, at: &str, e: &dyn std::fmt::Display) {
        line(&json!({ "msg": "error", "slot": self.slot.id, "at": at, "error": e.to_string() }));
    }

    /// Whether the slot's helper is still running, as after a runner restarted mid-run: the slot is not reset under it.
    fn helper_running(&self) -> bool {
        Command::new("systemctl")
            .args([
                "is-active",
                "--quiet",
                &format!("exec-pool-exec@{}.service", self.slot.id),
            ])
            .status()
            .is_ok_and(|s| s.success())
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

    /// Whether to claim now: always without an off timer, else only for a lease that ends before it fires. Logs a
    /// change, not every poll.
    fn claims_open(&self, paused: &mut bool) -> bool {
        let Some((timer, hold)) = &self.off_timer else {
            return true;
        };
        let fits = Command::new("systemctl")
            .args(["show", "-p", "LoadState", "-p", "NextElapseUSecRealtime"])
            .args(["--timestamp=unix", timer])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("systemctl: {e}"))
            .and_then(|o| String::from_utf8(o.stdout).map_err(|e| e.to_string()))
            .and_then(|show| {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|e| e.to_string())?;
                claim_fits(now.as_secs(), *hold, &show)
            });
        let open = fits.as_ref().is_ok_and(|f| *f);
        if open == *paused {
            *paused = !open;
            let msg = if open {
                "claims_resumed"
            } else {
                "claims_paused"
            };
            line(
                &json!({ "msg": msg, "slot": self.slot.id, "off_timer": timer, "error": fits.err() }),
            );
        }
        open
    }

    fn loop_forever(&self, store: &mut Store) -> ! {
        // the slot's state at startup is unknown: a runner that died mid-run left it as it was
        let mut dirty = true;
        let mut paused = false;
        loop {
            // a guest down or restarting (a switch restarts it) is waited for, not a reset that fails
            // a helper a dead runner started runs on with no one renewing its lease: expire it, reset nothing under it
            if dirty && self.helper_running() {
                if let Ok(changes) = store.reconcile() {
                    changes.iter().for_each(log_change);
                }
                thread::sleep(BACKOFF);
                continue;
            }
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
            if !self.claims_open(&mut paused) {
                thread::sleep(POLL);
                continue;
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

    /// Renews the attempt's lease; once a cancel is asked for or the lease is lost, writes the marker that stops the
    /// helper, and returns why. `stopping` is why it already did, if it did.
    fn beat(
        &self,
        store: &mut Store,
        m: &Manifest,
        stopping: Option<&'static str>,
    ) -> Option<&'static str> {
        let why = match store.heartbeat(&m.attempt_id, m.lease_epoch, self.lease_secs) {
            Ok(false) => None,
            Ok(true) => Some("cancel_requested"),
            Err(e @ (QueueError::NotLive(_) | QueueError::Fenced(_))) => {
                self.error("heartbeat", &e);
                Some("lease_lost")
            }
            // the lease may well still be live: the next beat tries again
            Err(e) => {
                self.error("heartbeat", &e);
                None
            }
        };
        if stopping.is_some() || why.is_none() {
            return stopping;
        }
        let tmp = self.runtime.join(format!("{CANCEL}.tmp"));
        let marked = fs::write(&tmp, m.cancel_token())
            .and_then(|()| fs::rename(&tmp, self.runtime.join(CANCEL)));
        match marked {
            Ok(()) => {
                line(
                    &json!({ "msg": "stopping", "slot": self.slot.id, "attempt": m.attempt_id,
                              "lease_epoch": m.lease_epoch, "reason": why }),
                );
                why
            }
            Err(e) => {
                self.error("cancel_marker", &e);
                None
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
        let marker = self.runtime.join(CANCEL);
        let written = match fs::remove_file(&marker) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => serde_json::to_string(&manifest).map_err(io::Error::other),
        }
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
        // a cancel asked for while leased: the helper sees the marker before its first step
        let mut stopping = self.beat(store, &manifest, None);
        let unit = format!("exec-pool-exec@{}.service", self.slot.id);
        match spawn_start(&unit) {
            Ok(mut child) => {
                let mut beat = Instant::now();
                let done = loop {
                    match child.try_wait() {
                        Ok(Some(status)) => break Ok(status),
                        Ok(None) => {}
                        Err(e) => break Err(e.to_string()),
                    }
                    if beat.elapsed() >= HEARTBEAT {
                        beat = Instant::now();
                        stopping = self.beat(store, &manifest, stopping);
                    }
                    thread::sleep(Duration::from_secs(1));
                };
                match done {
                    Ok(status) if status.success() => {}
                    Ok(status) => self.error("exec", &format!("systemctl start {unit}: {status}")),
                    Err(e) => self.error("exec", &e),
                }
            }
            Err(e) => self.error("exec", &e),
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
        if settled.is_ok() {
            let r = TaskResult::of(claim.task.command.agent, result.as_ref(), &stdout);
            if let Err(e) = store.record_result(id, epoch, &r) {
                self.error("record_result", &e);
            }
        }
        line(&json!({
            "msg": "run", "task_id": claim.task.id, "attempt": id, "lease_epoch": epoch, "slot": self.slot.id,
            "settle": format!("{to:?}"), "settled": settled.is_ok(), "output": dir,
            "stopped_for": stopping,
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
    let conninfo = var("EXEC_POOL_DB")?;
    // a remote runner's password is its unit's credential (LoadCredential), never in the environment
    let mut store = match std::env::var_os("CREDENTIALS_DIRECTORY") {
        Some(dir) => {
            let password = fs::read(Path::new(&dir).join("db-password"))
                .map_err(|e| format!("db-password credential: {e}"))?;
            Store::open_remote(&conninfo, password.strip_suffix(b"\n").unwrap_or(&password))
        }
        None => Store::open(&conninfo),
    }
    .map_err(|e| e.to_string())?;
    runner.loop_forever(&mut store)
}

struct Guest {
    slot: String,
    user: String,
    /// The runner's cancel marker, and what it holds when it names this attempt.
    cancel: (PathBuf, String),
    /// `K=V` for each step: the slot's agent route and a PATH that finds the agent.
    env: Vec<String>,
}

struct StepEnd {
    exit_code: Option<i32>,
    timed_out: bool,
    cancelled: bool,
}

impl Guest {
    fn cancelled(&self) -> bool {
        read_regular(&self.cancel.0).is_ok_and(|s| s == self.cancel.1)
    }

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
        let mut stopped = false;
        let (mut timed_out, mut cancelled) = (false, false);
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if !timed_out && !cancelled {
                timed_out = t.elapsed() > timeout;
                cancelled = !timed_out && self.cancelled();
            }
            if (timed_out || cancelled) && !stopped {
                stopped = true;
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
        let exit_code = guest_exit(status.code());
        Ok(StepEnd {
            exit_code,
            timed_out,
            // a command that exited 0 before the stop reached it finished: its run is not cancelled
            cancelled: cancelled && exit_code != Some(0),
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
            if self.cancelled() {
                result.cancelled = true;
                break;
            }
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
                    cancelled: false,
                }
            });
            if stage == Stage::Run {
                result.run_ms = ms(started);
            }
            result.exit_code = end.exit_code;
            result.timed_out = end.timed_out;
            result.cancelled = end.cancelled;
            if end.exit_code != Some(0) || end.timed_out || end.cancelled {
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
    let runtime = PathBuf::from(var("EXEC_POOL_RUNTIME")?);
    let path = runtime.join(MANIFEST);
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
        cancel: (runtime.join(CANCEL), manifest.cancel_token()),
        env: env.iter().map(|(k, v)| format!("{k}={v}")).collect(),
    };
    let mut result = ExecResult {
        schema_version: SchemaVersion::CURRENT,
        attempt_id: manifest.attempt_id.clone(),
        lease_epoch: manifest.lease_epoch,
        stage: Stage::Prepare,
        exit_code: None,
        timed_out: false,
        cancelled: false,
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
