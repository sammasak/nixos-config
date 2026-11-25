//! `exec-pool-runner`: the pool runner (#652) for one slot, and its slot-control helper.
//!
//! `run` (the queue's peer role, or `exec_pool_runner` on another host's, from `exec-pool-runner-<slot>.service`)
//! loops: reconcile, claim an attempt for the slot, accept `start`, write the manifest, start `exec-pool-exec@<slot>`,
//! then checkpoint and settle from its result, record the result, and release the slot with `dev-env-reset@<slot>`. It
//! begins no work before `start` is accepted, and never re-sends an event whose outcome is unknown: the lease expires
//! and `reconcile` decides. While the helper runs it renews the lease every [`HEARTBEAT`]; a cancel the heartbeat
//! reports, or a lease it finds lost, writes the cancel marker the helper stops at. A runner that dies renews nothing,
//! and the lease expires. A reset that fails quarantines the slot, in the queue too, until an operator removes the
//! marker. With `EXEC_POOL_OFF_TIMER` it claims only while `EXEC_POOL_CLAIM_SECS` from now ends before that timer
//! powers the host off, and `EXEC_POOL_DRAIN_SECS` before it stops the running attempt (the drain). A host's drain
//! request ([`DRAIN_REQUEST`], a deploy's) stops claims too and parks a running session turn the same way, while a
//! one-shot run goes on: the deploy rides it through, its restarted runner adopting it. With a credentials
//! directory it is a remote slot's runner, reaching the queue over TCP with the
//! `db-password` credential. Each state change is one JSON line on stdout.
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
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use exec_pool::queue::{Arm, Change, Claim, Park, QueueError, Store, TRANSCRIPT_BYTES, Transcript};
use exec_pool::runner::{
    CAPTURE_BYTES, DRAIN_REQUEST, ExecResult, Listed, MEMORY_KILLS, Manifest, PARK_PUSH_FAILURES,
    PREPARE_FAILURES, ParkedAt, QUICK_SECS, Session, Stage, Step, TurnHint, TurnSettle, claim_fits,
    decide, decide_turn, drain_holds, guest_exit, handed_back, holds_tree, oom_victims,
    parks_undelivered, read_bytes, read_regular, read_regular_up_to, receipt, relink, remote_head,
    session_checkpoint, tail, tree_check, while_unavailable,
};
use exec_pool::snapshot::{self, Git, Plan, Resume, landed, listed, plan};
use exec_pool::task_result::TaskResult;
use exec_pool::textfile;
use exec_pool::turn_log::{self, LOG_BYTES};
use exec_pool::wake::{self, Wake};
use exec_pool::workspace::{self, HomeId, SESSION_HOME, SESSION_WORK, Workspace, admit};
use exec_pool::{Agent, Event, Kind, ParkReason, Receipt, SchemaVersion, Settle, Slot, TaskSpec};
use exec_pool::{agent, pane};
use serde_json::{Value, json};

const USAGE: &str =
    "usage: exec-pool-runner run | exec SLOT   (configured by the environment its unit sets)";
const MANIFEST: &str = "manifest.json";
const RESULT: &str = "result.json";
/// Beside the manifest: the attempt the helper is to stop, as [`Manifest::cancel_token`].
const CANCEL: &str = "cancel";
/// Beside the manifest: a live session turn's [`TurnHint`], renewed every heartbeat.
const TURN_HINT: &str = "turn.json";
/// The idle grace before the first hint arrives: `homelab.execPool.idleGraceSecs`'s default.
const GRACE_SECS: u64 = 600;
/// Why the runner stops a run whose host powers off before it could end; it writes [`Manifest::drain_token`].
const HOST_DRAINING: &str = "host_draining";
/// The slot home the last admitted attempt ran in, beside the slot's run directories.
const LAST_HOME: &str = "home.json";
const POLL: Duration = Duration::from_secs(10);
/// How often the runner renews a lease and reads its cancel mark while the helper runs; the lease must be longer.
const HEARTBEAT: Duration = POLL;
const BACKOFF: Duration = Duration::from_secs(30);
const PREPARE_TIMEOUT: Duration = Duration::from_secs(300);
const PUSHED_TIMEOUT: Duration = Duration::from_secs(60);
/// Beside the slot's run directories: why the slot's dock holds work that is not on its remote, while it does.
const DOCK_BUSY: &str = "dock-busy";
/// Beside the manifest, the runner's: the transcript a session turn resumes, and the one its park keeps.
const TRANSCRIPT_IN: &str = "transcript-in.jsonl";
const TRANSCRIPT_OUT: &str = "transcript-out.jsonl";
/// How long a park tries to push the turn's work, and its pauses between tries: within the helper unit's timeout.
const PARK_PUSH_WAIT: Duration = Duration::from_secs(1800);
const PARK_PUSH_PAUSE: Duration = Duration::from_secs(30);
const PARK_PUSH_PAUSE_MAX: Duration = Duration::from_secs(300);
/// How long a turn's steps may take to leave the guest after the last one returned, before its dock is removed.
const DETACH_WAIT: Duration = Duration::from_secs(15);
/// How long a stopped step's command has after its SIGTERM before everything of it is killed.
const STOP_WAIT: Duration = Duration::from_secs(60);
const RESET_TRIES: u32 = 3;

/// Whether `hold_secs` from now ends before `timer` fires, as [`claim_fits`] reads its `systemctl show`.
fn fits(timer: &str, hold_secs: u32) -> Result<bool, String> {
    Command::new("systemctl")
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
            claim_fits(now.as_secs(), hold_secs, &show)
        })
}

fn var(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("{name} is not set"))
}

/// Each of `names` from the environment, or the first one missing.
fn vars<const N: usize>(names: [&str; N]) -> Result<[String; N], String> {
    let mut out = Vec::with_capacity(N);
    for name in names {
        out.push(var(name)?);
    }
    out.try_into()
        .map_err(|_| "a variable went missing".to_owned())
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

/// `systemctl VERB UNIT` as the runner's user: the polkit rule admits exactly starting this slot's two units and
/// clearing its reset's failed state.
fn systemctl(verb: &str, unit: &str) -> Result<(), String> {
    let out = Command::new("systemctl")
        .args([verb, unit])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("systemctl: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "systemctl {verb} {unit}: {} {}",
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
    /// The host's scheduled poweroff timer, how long before it claims stop, and how long before it a running attempt
    /// is drained.
    off_timer: Option<(String, u32, u32)>,
    /// How long an idle session agent stays in its pane, and how long while work waits for a slot.
    grace_secs: (u64, u64),
    /// The slot's declared settings (`EXEC_POOL_ARM`), recorded with each turn it parks.
    arm: Option<Arm>,
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
                Ok(timer) => {
                    let secs = |name: &str| {
                        var(name)?
                            .parse()
                            .map_err(|_| format!("{name} must be a number"))
                    };
                    Some((
                        timer,
                        secs("EXEC_POOL_CLAIM_SECS")?,
                        secs("EXEC_POOL_DRAIN_SECS")?,
                    ))
                }
                Err(_) => None,
            },
            grace_secs: (
                var("EXEC_POOL_IDLE_GRACE_SECS")?
                    .parse()
                    .map_err(|_| "EXEC_POOL_IDLE_GRACE_SECS must be a number".to_owned())?,
                var("EXEC_POOL_IDLE_GRACE_BUSY_SECS")?
                    .parse()
                    .map_err(|_| "EXEC_POOL_IDLE_GRACE_BUSY_SECS must be a number".to_owned())?,
            ),
            arm: std::env::var("EXEC_POOL_ARM")
                .ok()
                .map(|a| Arm::parse(&a).map_err(|e| format!("EXEC_POOL_ARM: {e}")))
                .transpose()?,
            slot,
        })
    }

    fn error(&self, at: &str, e: &dyn std::fmt::Display) {
        line(&json!({ "msg": "error", "slot": self.slot.id, "at": at, "error": e.to_string() }));
    }

    /// Whether the slot's helper is still running, as after a runner restarted mid-run: the slot is not reset under it.
    fn helper_running(&self) -> bool {
        // a oneshot is `activating` while it runs, which is-active does not count; a state systemd did not give (a
        // switch, a timeout) counts as running, so the slot is not reset nor a followed run settled under it
        Command::new("systemctl")
            .args(["show", "-p", "ActiveState", "--value"])
            .arg(format!("exec-pool-exec@{}.service", self.slot.id))
            .stdin(Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .is_none_or(|o| {
                !matches!(
                    String::from_utf8_lossy(&o.stdout).trim(),
                    "inactive" | "failed"
                )
            })
    }

    /// The manifest of the run a helper still runs for this slot, when the queue still holds its lease live: a
    /// restarted runner takes it over rather than let it expire. A lease already past its deadline is adopted too: its
    /// first beat finds it lost and stops the helper, and the reconcile sends it to review.
    fn adoptable(&self, store: &mut Store) -> Option<Manifest> {
        let m = read_regular(&self.runtime.join(MANIFEST))
            .ok()
            .and_then(|s| Manifest::parse(&s).ok())?;
        let live = store.live_on(&self.slot).ok().flatten()?;
        let same = (live.id.as_str(), live.lease_epoch) == (m.attempt_id.as_str(), m.lease_epoch);
        same.then_some(m)
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
    /// it could not reset is not offered again, nor one whose dock still holds a session tree (its detach failed).
    /// The refused unit's failed state is cleared, so the host is not left degraded; the marker, the queue's row and
    /// `ExecPoolSlotQuarantined` carry it instead.
    fn release(&self, store: &mut Store) -> bool {
        let t = Instant::now();
        let unit = format!("dev-env-reset@{}.service", self.slot.id);
        let stuck = fs::read_to_string(self.exec_dir.join(DOCK_BUSY));
        let last = match Self::reset(&unit) {
            Ok(()) if stuck.is_err() => {
                line(&json!({ "msg": "slot_reset", "slot": self.slot.id, "sanitize_ms": ms(t) }));
                return true;
            }
            Ok(()) => stuck.unwrap_or_default().trim_end().to_owned(),
            Err(e) => {
                if let Err(e) = systemctl("reset-failed", &unit) {
                    self.error("reset_failed", &e);
                }
                e
            }
        };
        if let Err(e) = fs::write(&self.quarantine, format!("{last}\n")) {
            self.error("quarantine_marker", &e);
        }
        if let Err(e) = store.quarantine(&self.slot, &last) {
            self.error("quarantine", &e);
        }
        line(
            &json!({ "msg": "slot_quarantined", "slot": self.slot.id, "reason": last,
                      "release": format!("rm {}", self.quarantine.display()) }),
        );
        false
    }

    /// `dev-env-reset@<slot>`, tried [`RESET_TRIES`] times; the last refusal.
    fn reset(unit: &str) -> Result<(), String> {
        let mut last = String::new();
        for try_ in 1..=RESET_TRIES {
            match systemctl("start", unit) {
                Ok(()) => return Ok(()),
                Err(e) => last = e,
            }
            if try_ < RESET_TRIES {
                thread::sleep(BACKOFF);
            }
        }
        Err(last)
    }

    /// Whether to claim now: not while the host's drain request holds; then always without an off timer, else only
    /// for a lease that ends before it fires. Logs a change, not every poll.
    fn claims_open(&self, paused: &mut bool) -> bool {
        let (open, why, error) = if self.drain_requested() {
            (false, "drain_requested", None)
        } else if let Some((timer, hold, _)) = &self.off_timer {
            let fits = fits(timer, *hold);
            (fits.as_ref().is_ok_and(|f| *f), "off_timer", fits.err())
        } else {
            (true, "", None)
        };
        if open == *paused {
            *paused = !open;
            let msg = if open {
                "claims_resumed"
            } else {
                "claims_paused"
            };
            line(&json!({ "msg": msg, "slot": self.slot.id, "reason": why, "error": error }));
        }
        open
    }

    /// Whether the host's drain request, beside every slot's runtime directory, holds now.
    fn drain_requested(&self) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        self.runtime
            .parent()
            .and_then(|d| read_regular(&d.join(DRAIN_REQUEST)).ok())
            .is_some_and(|m| drain_holds(&m, now))
    }

    /// Whether the host powers off within the drain lead; a timer it cannot read is no reason to stop a run.
    fn draining(&self) -> bool {
        self.off_timer
            .as_ref()
            .is_some_and(|(timer, _, lead)| fits(timer, *lead) == Ok(false))
    }

    fn loop_forever(&self, store: &mut Store) -> ! {
        // the slot's state at startup is unknown: a runner that died mid-run left it as it was
        let mut dirty = true;
        let mut paused = false;
        // whether the queue may still hold a quarantine row for the slot: unknown at startup, so cleared once
        let mut listed = true;
        loop {
            // a guest down or restarting (a switch restarts it) is waited for, not a reset that fails
            // a helper a dead runner started runs on with no one renewing its lease: expire it, reset nothing under it
            if dirty && self.helper_running() {
                if let Some(m) = self.adoptable(store) {
                    line(
                        &json!({ "msg": "adopted", "slot": self.slot.id, "attempt": m.attempt_id,
                                  "lease_epoch": m.lease_epoch }),
                    );
                    self.follow(store, &m, true, 0);
                    continue;
                }
                if let Ok(changes) = store.reconcile() {
                    changes.iter().for_each(log_change);
                }
                thread::sleep(BACKOFF);
                continue;
            }
            // the queue's row is rewritten while the marker stands: a write the database missed is not lost
            if let Ok(reason) = fs::read_to_string(&self.quarantine) {
                listed = true;
                if let Err(e) = store.quarantine(&self.slot, reason.trim_end()) {
                    self.error("quarantine", &e);
                }
                thread::sleep(BACKOFF);
                continue;
            }
            if dirty && (!self.guest_up() || !self.release(store)) {
                listed = true;
                thread::sleep(BACKOFF);
                continue;
            }
            // a clear the database missed is retried each pass until it lands
            if listed {
                match store.clear_quarantine(&self.slot) {
                    Ok(()) => listed = false,
                    Err(e) => self.error("clear_quarantine", &e),
                }
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

    /// Renews the attempt's lease; once a cancel is asked for, the lease is lost, the host's poweroff is within the
    /// drain lead or, for a session turn, its drain request holds, writes the marker that stops the helper (the drain's own token for the last), and returns why. `stopping` is why it already did, if it did.
    fn beat(
        &self,
        store: &mut Store,
        m: &Manifest,
        stopping: Option<&'static str>,
    ) -> Option<&'static str> {
        let why = match store.heartbeat(&m.attempt_id, m.lease_epoch, self.lease_secs) {
            Ok(false) if self.draining() || (m.session.is_some() && self.drain_requested()) => {
                Some(HOST_DRAINING)
            }
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
        if m.session.is_some() {
            self.hint(store, m);
        }
        if stopping.is_some() || why.is_none() {
            return stopping;
        }
        let tmp = self.runtime.join(format!("{CANCEL}.tmp"));
        let token = if why == Some(HOST_DRAINING) {
            m.drain_token()
        } else {
            m.cancel_token()
        };
        let marked =
            fs::write(&tmp, token).and_then(|()| fs::rename(&tmp, self.runtime.join(CANCEL)));
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

    /// Hands the queue the run's log tail in `dir` if it moved since `logged`, the tail it last took.
    fn put_log(
        &self,
        store: &mut Store,
        m: &Manifest,
        dir: &Path,
        logged: &mut Option<(u64, usize)>,
    ) {
        let Ok(Some((start, log))) = turn_log::read(dir) else {
            return;
        };
        if *logged == Some((start, log.len())) {
            return;
        }
        match store.put_log(&m.attempt_id, m.lease_epoch, start, &log) {
            Ok(()) => *logged = Some((start, log.len())),
            Err(e) => self.error("put_log", &e),
        }
    }

    /// Tells the helper of the session turn `m` its idle grace and the messages sent to it since its claim
    /// ([`TurnHint`]); a queue that does not answer leaves the last hint in place.
    fn hint(&self, store: &mut Store, m: &Manifest) {
        let upto = m.session.as_ref().map_or(0, |s| s.upto);
        let (mail, busy) = match store.during_turn(&m.task.id, upto) {
            Ok(r) => r,
            Err(e) => return self.error("turn_hint", &e),
        };
        let hint = TurnHint {
            schema_version: SchemaVersion::CURRENT,
            grace_secs: if busy {
                self.grace_secs.1
            } else {
                self.grace_secs.0
            },
            mail,
        };
        let tmp = self.runtime.join(format!("{TURN_HINT}.tmp"));
        let written = serde_json::to_string(&hint)
            .map_err(io::Error::other)
            .and_then(|json| fs::write(&tmp, json))
            .and_then(|()| fs::rename(&tmp, self.runtime.join(TURN_HINT)));
        if let Err(e) = written {
            self.error("turn_hint", &e);
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

    /// Settles the attempt from its run, or parks its session turn; where it went and whether that landed.
    fn finish(
        &self,
        store: &mut Store,
        manifest: &Manifest,
        result: Option<&ExecResult>,
        stdout: &str,
    ) -> (TurnSettle, bool) {
        let (id, epoch, task) = (
            manifest.attempt_id.as_str(),
            manifest.lease_epoch,
            &manifest.task,
        );
        let task_result = TaskResult::of(task.command.agent, result, stdout);
        // a park that cannot keep the transcript the helper took would resume the session without its last turn
        let transcript = self
            .take_transcript(result)
            .inspect_err(|e| self.error("transcript", e));
        let to = match (&manifest.session, &transcript) {
            (None, _) => TurnSettle::Settle(decide(id, epoch, task.command.agent, result, stdout)),
            (Some(_), Err(_)) => TurnSettle::Settle(Settle::NeedsReview),
            (Some(_), Ok(_)) => decide_turn(id, epoch, result, stdout),
        };
        let transcript = transcript.ok().flatten();
        // a queue restarting (its host deployed) is waited out while the lease lasts; no heartbeat renews it here
        let patience = Duration::from_secs(self.lease_secs.into());
        let settled = match to {
            TurnSettle::Settle(to) => while_unavailable(patience, POLL, || {
                Self::event(store, id, epoch, Kind::Checkpoint, None)
            })
            .and_then(|()| {
                let r = receipt(&task.id, id, epoch, to);
                while_unavailable(patience, POLL, || {
                    Self::event(store, id, epoch, Kind::Settle(to), r.as_ref())
                })
            })
            .map(|()| true),
            TurnSettle::Park(reason) => while_unavailable(patience, POLL, || {
                park(
                    store,
                    (id, epoch, task),
                    (
                        reason,
                        manifest
                            .session
                            .as_ref()
                            .map_or(0, |s| s.upto)
                            .max(result.and_then(|r| r.upto).unwrap_or(0)),
                        result.is_some_and(parks_undelivered),
                    ),
                    (
                        result.and_then(|r| r.parked_at.as_ref()),
                        result.and_then(|r| r.wake.clone()),
                        transcript.clone(),
                    ),
                    (
                        &task_result,
                        result.map(|r| r.oom_victims.clone()).unwrap_or_default(),
                    ),
                    self.arm.as_ref(),
                )
            })
            .map(|()| false),
        };
        match &settled {
            Err(e) => self.error("settle", e),
            // a park records its result itself
            Ok(true) => {
                if let Err(e) = while_unavailable(patience, POLL, || {
                    store.record_result(id, epoch, &task_result)
                }) {
                    self.error("record_result", &e);
                }
            }
            Ok(false) => {}
        }
        (to, settled.is_ok())
    }

    /// The transcript the claimed session turn resumes, beside the manifest as [`TRANSCRIPT_IN`], 0600; the last
    /// turn's of both directions removed first.
    fn put_transcript(&self, claim: &Claim) -> io::Result<()> {
        use std::os::unix::fs::OpenOptionsExt as _;
        for name in [TRANSCRIPT_IN, TRANSCRIPT_OUT] {
            match fs::remove_file(self.runtime.join(name)) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
        }
        let Some(t) = claim.turn.as_ref().and_then(|t| t.transcript.as_ref()) else {
            return Ok(());
        };
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(self.runtime.join(TRANSCRIPT_IN))?;
        io::Write::write_all(&mut f, &t.body)
    }

    /// The transcript the helper took from the turn for its park, if it took one.
    fn take_transcript(&self, result: Option<&ExecResult>) -> Result<Option<Transcript>, String> {
        let Some(project) = result.and_then(|r| r.transcript.clone()) else {
            return Ok(None);
        };
        let path = self.runtime.join(TRANSCRIPT_OUT);
        let body =
            read_bytes(&path, TRANSCRIPT_BYTES).map_err(|e| format!("{TRANSCRIPT_OUT}: {e}"))?;
        Ok(Some(Transcript { project, body }))
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
            session: session_of(claim),
        };
        // the last attempt's cancel marker and turn hint are not this one's
        let gone = |name: &str| match fs::remove_file(self.runtime.join(name)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
        let written = gone(CANCEL)
            .and_then(|()| gone(TURN_HINT))
            .and_then(|()| serde_json::to_string(&manifest).map_err(io::Error::other))
            .and_then(|json| {
                let tmp = self.runtime.join(format!("{MANIFEST}.tmp"));
                fs::write(&tmp, json)?;
                fs::rename(&tmp, self.runtime.join(MANIFEST))
            });
        if let Err(e) = written.and_then(|()| self.put_transcript(claim)) {
            self.error("manifest", &e);
            return false;
        }
        if let Err(e) = Self::event(store, id, epoch, Kind::Start, None) {
            self.error("start", &e);
            return false;
        }
        self.follow(store, &manifest, false, ms(claimed))
    }

    /// Follows the helper's run of `manifest` to its end, renewing the lease, then settles or parks the attempt from
    /// its result; `adopted`: an earlier runner of this slot started the helper, which runs on. Whether the slot ran
    /// anything and needs a reset.
    fn follow(
        &self,
        store: &mut Store,
        manifest: &Manifest,
        adopted: bool,
        claim_to_exec_ms: u64,
    ) -> bool {
        let exec = Instant::now();
        // a cancel asked for while leased: the helper sees the marker before its first step
        let mut stopping = self.beat(store, manifest, None);
        let dir = self.exec_dir.join(manifest.run_dir());
        let mut logged = None;
        let unit = format!("exec-pool-exec@{}.service", self.slot.id);
        let started = if adopted {
            Ok(None)
        } else {
            spawn_start(&unit).map(Some)
        };
        match started {
            Ok(mut child) => {
                let mut beat = Instant::now();
                let done = loop {
                    match child.as_mut().map(Child::try_wait) {
                        Some(Ok(Some(status))) => break Ok(Some(status)),
                        Some(Err(e)) => break Err(e.to_string()),
                        None if !self.helper_running() => break Ok(None),
                        Some(Ok(None)) | None => {}
                    }
                    if beat.elapsed() >= HEARTBEAT {
                        beat = Instant::now();
                        stopping = self.beat(store, manifest, stopping);
                        self.put_log(store, manifest, &dir, &mut logged);
                    }
                    thread::sleep(Duration::from_secs(1));
                };
                match done {
                    Ok(Some(status)) if !status.success() => {
                        self.error("exec", &format!("systemctl start {unit}: {status}"));
                    }
                    Ok(_) => {}
                    Err(e) => self.error("exec", &e),
                }
            }
            Err(e) => self.error("exec", &e),
        }
        let exec_ms = ms(exec);
        // before the park or settle, so a reader that sees the turn end reads its whole log
        self.put_log(store, manifest, &dir, &mut logged);
        let result = read_regular(&dir.join(RESULT))
            .map_err(|e| e.to_string())
            .and_then(|s| ExecResult::parse(&s).map_err(|e| e.to_string()))
            .inspect_err(|e| self.error("result", e))
            .ok();
        let stdout = String::from_utf8_lossy(&read_capture(&dir.join("stdout"))).into_owned();
        let (to, settled) = self.finish(store, manifest, result.as_ref(), &stdout);
        line(&json!({
            "msg": "run", "task_id": manifest.task.id, "attempt": manifest.attempt_id, "lease_epoch": manifest.lease_epoch, "slot": self.slot.id,
            "settle": format!("{to:?}"), "settled": settled, "output": dir,
            "stopped_for": stopping,
            "exit_code": result.as_ref().and_then(|r| r.exit_code),
            "timed_out": result.as_ref().map(|r| r.timed_out),
            "oom_kills": result.as_ref().and_then(|r| r.oom_kills),
            "oom_victims": result.as_ref().map(|r| r.oom_victims.as_slice()),
            "failed_step": result.as_ref().and_then(|r| r.failed_step.as_deref()),
            "stdout_tail": result.as_ref().map(|r| r.stdout_tail.as_str()),
            "stderr_tail": result.as_ref().map(|r| r.stderr_tail.as_str()),
            "claim_to_exec_ms": claim_to_exec_ms, "exec_ms": exec_ms,
            "prepare_ms": result.as_ref().map(|r| r.prepare_ms), "run_ms": result.as_ref().map(|r| r.run_ms),
        }));
        true
    }
}

/// A session task's turn, as its claim hands it over.
fn session_of(claim: &Claim) -> Option<Session> {
    claim.turn.as_ref().map(|t| Session {
        uuid: t.session_uuid.clone(),
        // the first turn's prompt carries it in its prefix
        input: if t.first {
            t.input.clone()
        } else {
            format!("{}\n\n{}", t.input, agent::SESSION_PARK.trim_end())
        },
        upto: t.upto,
        transcript: t.transcript.as_ref().map(|x| x.project.clone()),
    })
}

/// Parks the session turn `attempt` at `epoch` with its result, the inbox read up to `upto`, the checkpoint that
/// names where the remote holds its work, the turn's `wake`, the agent's transcript, what the OOM killer killed in the
/// slot and the slot's arm.
fn park(
    store: &mut Store,
    (attempt, epoch, task): (&str, u64, &TaskSpec),
    (reason, upto, undelivered): (ParkReason, i64, bool),
    (at, wake, transcript): (Option<&ParkedAt>, Option<Wake>, Option<Transcript>),
    (result, memory_killed): (&TaskResult, Vec<String>),
    arm: Option<&Arm>,
) -> Result<(), QueueError> {
    let (_, changes) = store.park(
        attempt,
        epoch,
        &Park {
            reason,
            checkpoint: at.map(|at| session_checkpoint(task, epoch, at)),
            result: result.clone(),
            upto,
            undelivered,
            wake,
            transcript,
            arm: arm.cloned(),
            memory_killed,
        },
    )?;
    changes.iter().for_each(log_change);
    Ok(())
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
    /// The runner's cancel marker, and what it holds when it names this attempt: for a cancel, and for a drain.
    cancel: (PathBuf, String, String),
    /// `K=V` for each step: the slot's agent route and a PATH that finds the agent.
    env: Vec<String>,
    /// Where the agent step's streams go as well, as they come; none if the run's log could not be started.
    log: Option<Arc<turn_log::Writer>>,
}

struct StepEnd {
    exit_code: Option<i32>,
    timed_out: bool,
    cancelled: bool,
    /// The helper stopped it for the runner's marker, whatever its exit.
    stopped: bool,
}

impl Guest {
    /// The marker names this attempt, for a cancel or a drain.
    fn cancelled(&self) -> bool {
        read_regular(&self.cancel.0).is_ok_and(|s| s == self.cancel.1 || s == self.cancel.2)
    }

    /// The marker names this attempt for a drain.
    fn draining(&self) -> bool {
        read_regular(&self.cancel.0).is_ok_and(|s| s == self.cancel.2)
    }

    /// Records in `result` why the marker stopped the attempt.
    fn stopped(&self, result: &mut ExecResult) {
        if self.draining() {
            result.drained = true;
        } else {
            result.cancelled = true;
        }
    }

    /// Copies at most `keep` bytes of `from` into `to` and drains the rest, so a chatty task cannot fill the host;
    /// all of it into `log` as it comes, which keeps the tail.
    fn capture(
        from: impl io::Read + Send + 'static,
        (to, keep): (&File, u64),
        log: Option<Arc<turn_log::Writer>>,
    ) -> io::Result<thread::JoinHandle<io::Result<()>>> {
        let mut to = to.try_clone()?;
        Ok(thread::spawn(move || {
            let mut from = from;
            let (mut buf, mut left) = ([0; 8192], keep);
            loop {
                let n = match from.read(&mut buf) {
                    Ok(0) => return Ok(()),
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                };
                let got = buf.get(..n).unwrap_or_default();
                let kept = got
                    .get(..usize::try_from(left).unwrap_or(usize::MAX).min(n))
                    .unwrap_or_default();
                io::Write::write_all(&mut to, kept)?;
                left = left.saturating_sub(u64::try_from(kept.len()).unwrap_or(u64::MAX));
                // the log is for watching: a full disk there does not fail the run
                if let Some(log) = &log {
                    let _ = log.write(got);
                }
            }
        }))
    }

    /// One command in the guest as its user, in its home, as a transient unit the helper stops at `timeout`.
    /// `cancellable`: the runner's cancel marker stops it.
    fn step(
        &self,
        unit: (&str, bool),
        argv: &[String],
        timeout: Duration,
        (out, err): (&File, &File),
        log: Option<&Arc<turn_log::Writer>>,
    ) -> io::Result<StepEnd> {
        self.step_watched(
            unit,
            argv,
            (timeout, (out, CAPTURE_BYTES), err),
            log,
            &mut never,
        )
    }

    /// [`Guest::step`], keeping up to `keep` bytes of its stdout and asking `watch` on every poll whether to stop it,
    /// which is neither a timeout nor a cancel, and whether its agent is idle, which restarts its time limit.
    fn step_watched(
        &self,
        (unit, cancellable): (&str, bool),
        argv: &[String],
        (timeout, (out, keep), err): (Duration, (&File, u64), &File),
        log: Option<&Arc<turn_log::Writer>>,
        watch: &mut dyn FnMut() -> Watch,
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
                // a stop is the command's SIGTERM alone, so the agent ends its turn before its children are killed
                "-p",
                "KillMode=mixed",
                // the kernel's OOM kill of one process (a nix eval) fails that command, not the agent's whole turn
                "-p",
                "OOMPolicy=continue",
                "-p",
                &format!("TimeoutStopSec={}", STOP_WAIT.as_secs()),
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
                .map(|s| Self::capture(s, (out, keep), log.cloned()))
                .transpose()?,
            child
                .stderr
                .take()
                .map(|s| Self::capture(s, (err, CAPTURE_BYTES), log.cloned()))
                .transpose()?,
        ];
        let mut t = Instant::now();
        let mut stopped = false;
        let (mut timed_out, mut cancelled) = (false, false);
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            let watched = if stopped || timed_out || cancelled {
                Watch::Busy
            } else {
                watch()
            };
            let ran_out;
            (t, ran_out) = limit(t, watched, Instant::now(), timeout);
            if !timed_out && !cancelled {
                timed_out = ran_out;
                cancelled = !timed_out && cancellable && self.cancelled();
            }
            if !stopped && (timed_out || cancelled || watched == Watch::Stop) {
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
            stopped: cancelled,
        })
    }

    /// The task's branch as its repository shows it, listed into the run directory's file `name`; why a listing failed
    /// goes to `err`. A cancel does not stop it, so a cancelled run's push is still found.
    fn remote_head(
        &self,
        m: &Manifest,
        (git, env): (&str, &str),
        (dir, name): (&Path, &str),
        err: &File,
    ) -> Listed {
        let note = |e: &dyn std::fmt::Display| {
            let _ = io::Write::write_all(
                &mut &*err,
                format!("exec-pool-exec: {name}: {e}\n").as_bytes(),
            );
        };
        let Some((argv, branch)) = m
            .pushed_check(git, env)
            .and_then(|argv| agent::branch(&m.task).map(|b| (argv, b)))
            .inspect_err(|e| note(e))
            .ok()
        else {
            return Listed::Unknown;
        };
        let path = dir.join(name);
        match File::create(&path).and_then(|f| {
            self.step(
                ("exec-pool-pushed", false),
                &argv,
                PUSHED_TIMEOUT,
                (&f, err),
                None,
            )
        }) {
            Ok(end) if end.exit_code == Some(0) => {
                remote_head(&String::from_utf8_lossy(&read_capture(&path)), &branch)
                    .map_or(Listed::Absent, Listed::At)
            }
            Ok(end) => {
                note(&format!("git ls-remote exited {:?}", end.exit_code));
                Listed::Unknown
            }
            Err(e) => {
                note(&e);
                Listed::Unknown
            }
        }
    }

    /// Records in `result` what the run handed back once its agent ran: the branch if it pushed to it ([`handed_back`]
    /// against the listing `before`), and whether that branch holds the whole tree ([`holds_tree`] of [`tree_check`],
    /// its output in the run directory's file `tree`).
    fn hand_back(
        &self,
        (m, ws): (&Manifest, &Workspace),
        (git, env): (&str, &str),
        before: &Listed,
        (dir, err): (&Path, &File),
        result: &mut ExecResult,
    ) {
        let after = self.remote_head(m, (git, env), (dir, "pushed"), err);
        result.branch = agent::branch(&m.task)
            .ok()
            .and_then(|b| handed_back(before, &after, &b));
        let checkout = match &m.session {
            Some(_) => SESSION_WORK.to_owned(),
            None => ws.checkout(),
        };
        let path = dir.join("tree");
        let argv = tree_check(git, env, &checkout);
        let status = match File::create(&path).and_then(|f| {
            self.step(
                ("exec-pool-tree", false),
                &argv,
                PUSHED_TIMEOUT,
                (&f, err),
                None,
            )
        }) {
            Ok(end) if end.exit_code == Some(0) => {
                Some(String::from_utf8_lossy(&read_capture(&path)).into_owned())
            }
            end => {
                let _ = io::Write::write_all(
                    &mut &*err,
                    format!("exec-pool-exec: tree: {:?}\n", end.map(|e| e.exit_code)).as_bytes(),
                );
                None
            }
        };
        result.handed_back = Some(holds_tree(&after, status.as_deref()));
    }

    /// Runs `steps` in order until one fails or times out, recording in `result` where it stopped; `t` is when the
    /// run's preparing began; `watch` as [`Guest::step_watched`]'s, for the run's step. Whether every step ran to
    /// exit 0.
    fn steps(
        &self,
        steps: Vec<Step>,
        (timeout, t): (Duration, Instant),
        (out, err): (&File, &File),
        result: &mut ExecResult,
        watch: &mut dyn FnMut() -> Watch,
    ) -> bool {
        for Step {
            stage,
            unit,
            argv,
            limit_secs,
        } in steps
        {
            // a stop before a step leaves the stage as it was: a turn stopped before its agent ran is still preparing
            if self.cancelled() {
                self.stopped(result);
                break;
            }
            if stage == Stage::Run {
                result.prepare_ms = ms(t);
            }
            result.stage = stage;
            let limit = match (stage, limit_secs) {
                (_, Some(secs)) => Duration::from_secs(secs),
                (Stage::Prepare, None) => PREPARE_TIMEOUT,
                (Stage::Run, None) => timeout,
            };
            let started = Instant::now();
            let log = self.log.as_ref().filter(|_| stage == Stage::Run);
            let end = match stage {
                Stage::Run => self.step_watched(
                    (unit, true),
                    &argv,
                    (limit, (out, CAPTURE_BYTES), err),
                    log,
                    watch,
                ),
                Stage::Prepare => self.step((unit, true), &argv, limit, (out, err), log),
            }
            .map_err(|e| format!("{unit}: {e}"));
            let end = end.unwrap_or_else(|e| {
                let _ =
                    io::Write::write_all(&mut &*err, format!("exec-pool-exec: {e}\n").as_bytes());
                StepEnd {
                    exit_code: None,
                    timed_out: false,
                    cancelled: false,
                    stopped: false,
                }
            });
            if stage == Stage::Run {
                result.run_ms = ms(started);
            }
            result.exit_code = end.exit_code;
            result.timed_out = end.timed_out;
            // a drained agent that ends its turn on the SIGTERM and exits 0 was still stopped mid-turn
            if end.cancelled || (end.stopped && self.draining()) {
                self.stopped(result);
                return false;
            }
            if end.exit_code != Some(0) || end.timed_out {
                if stage == Stage::Prepare {
                    result.failed_step = Some(unit.to_owned());
                }
                return false;
            }
        }
        !(result.cancelled || result.drained)
    }

    /// The session turn's agent step: a resume once the transcript probe finds the session, its start before; and
    /// which.
    fn turn(
        &self,
        m: &Manifest,
        ws: &Workspace,
        (dtach, env, find): (Option<&str>, &str, &str),
        (dir, err): (&Path, &File),
    ) -> Result<(Step, agent::Turn), String> {
        let session = m
            .session
            .as_ref()
            .ok_or("a one-shot manifest has no turn")?;
        let turn = if self.transcript(find, session, (dir, err))?.is_some() {
            agent::Turn::Resume
        } else {
            agent::Turn::Start
        };
        m.turn(ws, (dtach, env), turn)
            .map(|step| (step, turn))
            .map_err(|e| format!("manifest: {e}"))
    }

    /// Where the session's transcript is in the dock's HOME, by [`agent::transcript_probe`]: found, none (also when
    /// Claude has written no project yet, find's exit 1), or a probe that did not finish, which fails the turn's
    /// preparing rather than start a session that may exist.
    fn transcript(
        &self,
        find: &str,
        session: &Session,
        (dir, err): (&Path, &File),
    ) -> Result<Option<String>, String> {
        let path = dir.join("transcript");
        let argv = agent::transcript_probe(find, SESSION_HOME, &session.uuid);
        let limit = Duration::from_secs(QUICK_SECS);
        let end = File::create(&path)
            .and_then(|f| self.step(("exec-pool-probe", false), &argv, limit, (&f, err), None))
            .map_err(|e| format!("exec-pool-probe: {e}"))?;
        match end.exit_code {
            Some(0) => Ok(Some(
                String::from_utf8_lossy(&read_capture(&path))
                    .trim_end()
                    .to_owned(),
            )
            .filter(|p| !p.is_empty())),
            Some(1) => Ok(None),
            other => Err(format!("exec-pool-probe ended with {other:?}")),
        }
    }

    /// `argv` as the quick step `unit`, its stdout in the run directory's file of the unit's name; that stdout, its
    /// end trimmed, when it exits 0.
    fn output(
        &self,
        unit: &str,
        argv: &[String],
        (dir, err): (&Path, &File),
    ) -> Result<String, String> {
        let path = dir.join(unit);
        let end = File::create(&path)
            .and_then(|f| self.step((unit, false), argv, PREPARE_TIMEOUT, (&f, err), None))
            .map_err(|e| format!("{unit}: {e}"))?;
        match end.exit_code {
            Some(0) => Ok(String::from_utf8_lossy(&read_capture(&path))
                .trim_end()
                .to_owned()),
            other => Err(format!("{unit} ended with {other:?}")),
        }
    }

    /// How the turn's clone gets back to where the last park left the session, from its remote's listing.
    fn resume(
        &self,
        m: &Manifest,
        (git, env): (&str, &str),
        dir: (&Path, &File),
    ) -> Result<Resume, String> {
        let branch = agent::branch(&m.task).map_err(|e| e.to_string())?;
        let wip = snapshot::wip_ref(&m.task).map_err(|e| e.to_string())?;
        let g = Git {
            env,
            git,
            checkout: SESSION_WORK,
        };
        let listing = self.output(
            "exec-pool-listed",
            &g.list(&m.task.source.repo, &branch, &wip),
            dir,
        )?;
        Ok(Resume::of(
            listed(&listing, &format!("refs/heads/{branch}")),
            listed(&listing, &wip),
        ))
    }

    /// The runner's cancel marker names this attempt for a cancel, not a drain.
    fn cancel_asked(&self) -> bool {
        read_regular(&self.cancel.0).is_ok_and(|s| s == self.cancel.1)
    }

    /// Whether the turn's steps are all gone from the guest, waiting up to [`DETACH_WAIT`]: a step's process left
    /// running would follow its tree out of the dock.
    fn steps_gone(&self) -> bool {
        let t = Instant::now();
        loop {
            // a guest that is not running holds no process
            let up = Command::new("systemctl")
                .args([
                    "is-active",
                    "--quiet",
                    &format!("container@{}.service", self.slot),
                ])
                .status()
                .is_ok_and(|s| s.success());
            if !up {
                return true;
            }
            let running = Command::new("systemctl")
                .args([
                    "-M",
                    &self.slot,
                    "list-units",
                    "--no-legend",
                    "--plain",
                    "exec-pool-*",
                ])
                .output()
                .map(|o| !o.stdout.is_empty() || !o.status.success());
            match running {
                Ok(false) => return true,
                _ if t.elapsed() > DETACH_WAIT => return false,
                _ => thread::sleep(Duration::from_secs(1)),
            }
        }
    }
}

/// The largest transcript a turn's verdict reads.
const TRANSCRIPT_LIMIT: u64 = 256 << 20;
/// How long one Herdr call may take beyond the wait it is told.
const HERDR_CALL: Duration = Duration::from_secs(30);
/// How often the turn's pane is read.
const PANE_POLL: Duration = Duration::from_secs(2);
/// How long the agent's terminal may take to appear, and Herdr to see the agent in the pane once it did.
const AGENT_START: Duration = Duration::from_secs(60);
const AGENT_SEEN: Duration = Duration::from_secs(180);
/// How long a closed agent may take to exit before its unit is stopped.
const AGENT_CLOSE: Duration = Duration::from_secs(30);
/// How long Herdr may see no agent in the pane (closed, or Herdr restarted) before the pane is opened again.
const PANE_LOST: Duration = Duration::from_secs(30);

/// The host user's Herdr, where a slot's pane is (`EXEC_POOL_HERDR`: the argv up to and with `herdr`, run as that
/// user), and the command the pane runs to attach to the turn's agent in the guest (`EXEC_POOL_ATTACH`).
struct Herdr {
    argv: Vec<String>,
    attach: String,
    slot: String,
}

impl Herdr {
    fn from_env(slot: &str) -> Result<Option<Self>, String> {
        let Ok(argv) = std::env::var("EXEC_POOL_HERDR") else {
            return Ok(None);
        };
        let argv: Vec<String> =
            serde_json::from_str(&argv).map_err(|e| format!("EXEC_POOL_HERDR: {e}"))?;
        if argv.is_empty() {
            return Err("EXEC_POOL_HERDR is empty".to_owned());
        }
        Ok(Some(Self {
            argv,
            attach: var("EXEC_POOL_ATTACH")?,
            slot: slot.to_owned(),
        }))
    }

    /// One call's JSON answer, `Null` for a command that prints nothing on success (`pane run`, `pane send-keys`);
    /// one that does not end within `wait` and [`HERDR_CALL`] is killed.
    fn call(&self, args: &[&str], wait: Duration) -> Result<Value, String> {
        let what = args.iter().take(2).copied().collect::<Vec<_>>().join(" ");
        let (cmd, rest) = self.argv.split_first().ok_or("no herdr")?;
        let mut child = Command::new(cmd)
            .args(rest)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("herdr {what}: {e}"))?;
        let (out, err) = (
            child.stdout.take().map(drain),
            child.stderr.take().map(drain),
        );
        let limit = wait.saturating_add(HERDR_CALL);
        let t = Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) if t.elapsed() > limit => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break Err(format!(
                        "herdr {what} did not answer in {} s",
                        limit.as_secs()
                    ));
                }
                Ok(None) => thread::sleep(Duration::from_millis(50)),
                Err(e) => break Err(format!("herdr {what}: {e}")),
            }
        };
        let join = |h: Option<thread::JoinHandle<Vec<u8>>>| {
            h.and_then(|h| h.join().ok()).unwrap_or_default()
        };
        let (out, err) = (join(out), join(err));
        if !status?.success() {
            return Err(format!("herdr {what}: {}", tail(&err).trim()));
        }
        if out.trim_ascii().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&out).map_err(|e| format!("herdr {what}: {e}"))
    }

    /// Whether the host user's Herdr server is up.
    fn running(&self) -> Result<(), String> {
        let status = self.call(&["status", "--json"], Duration::ZERO)?;
        if status.pointer("/server/running") == Some(&Value::Bool(true)) {
            Ok(())
        } else {
            Err("the host user's Herdr server is not running".to_owned())
        }
    }

    /// Closes every workspace of this slot's, so an idle slot shows none.
    fn close_slots(&self) {
        let Ok(list) = self.call(&["workspace", "list"], Duration::ZERO) else {
            return;
        };
        let ids = list
            .pointer("/result/workspaces")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|w| {
                w.get("label")
                    .and_then(Value::as_str)
                    .is_some_and(|l| pane::is_slots(l, &self.slot))
            })
            .filter_map(|w| w.get("workspace_id").and_then(Value::as_str));
        for id in ids {
            self.close(id);
        }
    }

    /// A new workspace labelled `label` whose pane attaches to the turn's agent: its id and its pane's. One whose pane
    /// could not attach is closed again.
    fn open(&self, label: &str) -> Result<(String, String), String> {
        self.close_slots();
        let created = self.call(
            &["workspace", "create", "--label", label, "--no-focus"],
            Duration::ZERO,
        )?;
        let id = |at: &str| {
            created
                .pointer(at)
                .and_then(Value::as_str)
                .map(str::to_owned)
        };
        let (Some(workspace), Some(pane)) = (
            id("/result/workspace/workspace_id"),
            id("/result/root_pane/pane_id"),
        ) else {
            return Err(format!(
                "herdr workspace create named no workspace and pane: {created}"
            ));
        };
        if let Err(e) = self.call(&["pane", "run", &pane, &self.attach], Duration::ZERO) {
            self.close(&workspace);
            return Err(e);
        }
        Ok((workspace, pane))
    }

    fn close(&self, workspace: &str) {
        let _ = self.call(&["workspace", "close", workspace], Duration::ZERO);
    }

    /// Prompts `text` into the agent in `pane`; an Enter it dropped is sent again. A prompt Herdr refused (a blocked
    /// agent, none in the pane) is an error: no Enter answers a dialog.
    fn prompt(&self, pane: &str, text: &str) -> Result<(), String> {
        let sent = self.call(
            &[
                "agent",
                "prompt",
                pane,
                text,
                "--wait",
                "--until",
                "working",
                "--until",
                "done",
                "--timeout",
                "15000",
            ],
            Duration::from_secs(15),
        );
        match sent {
            // submitted, but Herdr saw no work start in time
            Err(e) if e.contains(r#""code":"timeout""#) || e.contains("agent_prompt_stalled") => {
                let _ = self.call(&["agent", "send-keys", pane, "Enter"], Duration::ZERO);
                Ok(())
            }
            Err(e) => Err(e),
            Ok(_) => Ok(()),
        }
    }

    /// What Herdr sees of the agent in `pane`; `None`: no agent there.
    fn seen(&self, pane: &str) -> Result<Option<pane::Seen>, String> {
        self.call(&["agent", "list"], Duration::ZERO)
            .map(|list| pane::seen(&list, pane))
    }
}

/// What a step's watch tells it on a poll.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Watch {
    Busy,
    /// Its agent waits for input: its time limit starts again.
    Idle,
    Stop,
}

/// A step's time limit after a poll at `now` found `watched`, from `since`: its new start and whether it ran out.
///
/// It counts the agent's work since it was last idle, not its pause, so an agent that never idles is cut at `timeout`.
fn limit(since: Instant, watched: Watch, now: Instant, timeout: Duration) -> (Instant, bool) {
    let since = if watched == Watch::Idle { now } else { since };
    (since, now.saturating_duration_since(since) > timeout)
}

/// The watch of a step that only its time limit and the runner's marker stop.
const fn never() -> Watch {
    Watch::Busy
}

/// Everything `s` gives, read in a thread of its own.
fn drain<R: io::Read + Send + 'static>(mut s: R) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut b = Vec::new();
        let _ = s.read_to_end(&mut b);
        b
    })
}

/// Where the turn's pane is.
enum Phase {
    /// Waiting for the agent's terminal, then opening the pane.
    Open,
    /// The pane is open; waiting for Herdr to see the agent in it.
    Detect(String, Instant),
    /// The agent has its prompt: working, or idle in its pause.
    Watch(String),
    /// The pause's grace ran out and the agent was closed; waiting for it to exit.
    Close(Instant),
}

/// The turn's agent in the slot's Herdr pane: opened, named, prompted as the coordinator prompted a named worker,
/// and watched ([`pane::TurnWatch`]). Idle, it pauses in the pane for the runner's grace ([`TurnHint`]), in which
/// the owner may type to it and a message sent to the session is prompted into it, each making it work on in the same
/// turn; then (at once when it asked for a timer) it is closed as a person would (ctrl+c twice), so Claude writes
/// its transcript's end. `poll` tells the agent's step whether it is idle and when to stop it.
struct PaneTurn<'a> {
    herdr: &'a Herdr,
    /// The slot and the agent step's unit, whose Bash tool commands keep it busy ([`pane::tool_shell`]).
    unit: (&'a str, &'static str),
    label: String,
    name: String,
    home: &'a Path,
    uuid: &'a str,
    input: &'a str,
    /// The runner's hint for this turn.
    hint: PathBuf,
    grace_secs: u64,
    phase: Phase,
    started: Instant,
    /// When the turn started, against which a subagent's meta is told to be this turn's ([`subagents`]).
    since: SystemTime,
    polled: Option<Instant>,
    last: Watch,
    lost: Option<Instant>,
    watch: Option<pane::TurnWatch>,
    /// The transcript's lines before the first prompt; `None` until it was prompted.
    from: Option<usize>,
    /// The last inbox message prompted: the claim's, then a hint's.
    upto: i64,
    /// The agent was idle at the last poll.
    idle: bool,
    /// The agent was closed idle, its turn ended.
    ended: bool,
    /// Every workspace the turn opened, closed by id once it ends whatever its label shows by then.
    opened: Vec<String>,
}

impl<'a> PaneTurn<'a> {
    fn new(
        herdr: &'a Herdr,
        (m, hint): (&Manifest, PathBuf),
        (home, unit): (&'a Path, (&'a str, &'static str)),
        uuid: &'a str,
        input: &'a str,
    ) -> Self {
        Self {
            herdr,
            unit,
            label: pane::label(&m.slot, &m.task.idempotency_key),
            name: pane::agent_name(&m.task.id),
            home,
            uuid,
            input,
            hint,
            grace_secs: GRACE_SECS,
            phase: Phase::Open,
            started: Instant::now(),
            since: SystemTime::now(),
            polled: None,
            last: Watch::Busy,
            lost: None,
            watch: None,
            from: None,
            upto: m.session.as_ref().map_or(0, |s| s.upto),
            idle: false,
            ended: false,
            opened: Vec::new(),
        }
    }

    /// Moves the pane on at most every [`PANE_POLL`], and between polls tells what the last one found.
    fn poll(&mut self, note: &dyn Fn(&str, &dyn std::fmt::Display)) -> Watch {
        if self.polled.is_some_and(|t| t.elapsed() < PANE_POLL) {
            return self.last;
        }
        self.polled = Some(Instant::now());
        self.last = self.step(note);
        self.last
    }

    fn step(&mut self, note: &dyn Fn(&str, &dyn std::fmt::Display)) -> Watch {
        let fail = |e: &dyn std::fmt::Display| {
            note("pane", e);
            Watch::Stop
        };
        match &self.phase {
            Phase::Open => {
                if home_file(self.home, agent::AGENT_SOCKET)
                    .symlink_metadata()
                    .is_ok()
                {
                    match self.herdr.open(&self.label) {
                        Ok((w, p)) => {
                            self.opened.push(w);
                            self.phase = Phase::Detect(p, Instant::now());
                        }
                        Err(e) => return fail(&e),
                    }
                } else if self.started.elapsed() > AGENT_START {
                    return fail(&"the agent's terminal never appeared");
                }
                Watch::Busy
            }
            Phase::Detect(p, since) => {
                let p = p.clone();
                match self.herdr.seen(&p) {
                    Ok(Some(_)) => {
                        if let Err(e) = self
                            .herdr
                            .call(&["agent", "rename", &p, &self.name], Duration::ZERO)
                        {
                            note("pane name", &e);
                        }
                        if self.watch.is_none()
                            && let Err(e) = self.first_prompt(&p)
                        {
                            return fail(&e);
                        }
                        self.phase = Phase::Watch(p);
                        Watch::Busy
                    }
                    _ if since.elapsed() > AGENT_SEEN => fail(&"Herdr saw no agent in the pane"),
                    _ => Watch::Busy,
                }
            }
            Phase::Watch(p) => {
                let p = p.clone();
                let seen = self.herdr.seen(&p).ok().flatten();
                if seen.is_none() {
                    if self.lost.get_or_insert_with(Instant::now).elapsed() > PANE_LOST {
                        note("pane", &"no agent in the pane: opening it again");
                        self.lost = None;
                        self.phase = Phase::Open;
                    }
                    return Watch::Busy;
                }
                self.lost = None;
                self.take_hint(&p, seen, note);
                let now = u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX);
                // the host's /proc is read only once Herdr shows the agent settled
                let jobs = seen.is_some_and(|s| s.settled)
                    && (self.jobs() || subagents(self.home, self.uuid, self.since));
                let idle = self.watch.as_mut().and_then(|w| w.idle_ms(seen, jobs, now));
                self.idle = idle.is_some();
                let waiting = self.home.join(wake::FILE).symlink_metadata().is_ok();
                if pane::parks(idle, self.grace_secs, waiting) {
                    self.ended = true;
                    let _ = self
                        .herdr
                        .call(&["agent", "send-keys", &p, "ctrl+c"], Duration::ZERO);
                    thread::sleep(Duration::from_millis(500));
                    let _ = self
                        .herdr
                        .call(&["agent", "send-keys", &p, "ctrl+c"], Duration::ZERO);
                    self.phase = Phase::Close(Instant::now());
                }
                if self.idle { Watch::Idle } else { Watch::Busy }
            }
            Phase::Close(since) if since.elapsed() > AGENT_CLOSE => Watch::Stop,
            Phase::Close(_) => Watch::Idle,
        }
    }

    /// Whether a Bash tool command ([`pane::tool_shell`]) or a detached job ([`pane::detached`]) of the agent runs,
    /// by the host's /proc; a process that exits mid-read is not one.
    fn jobs(&self) -> bool {
        let Ok(procs) = fs::read_dir("/proc") else {
            return false;
        };
        let mut unit = Vec::new();
        for e in procs.filter_map(Result::ok) {
            let p = e.path();
            let Some(pid) = e.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
                continue;
            };
            let Some(cg) = fs::read_to_string(p.join("cgroup"))
                .ok()
                .filter(|cg| pane::in_unit(cg, self.unit))
            else {
                continue;
            };
            if fs::read(p.join("cmdline")).is_ok_and(|c| pane::tool_shell(&cg, &c, self.unit)) {
                return true;
            }
            if let Some(proc) = fs::read_to_string(p.join("stat"))
                .ok()
                .and_then(|s| pane::Proc::of_stat(pid, &s))
            {
                unit.push(proc);
            }
        }
        pane::detached(&unit)
    }

    /// Reads the runner's hint: its grace, and the messages sent to the session since the last one prompted, which
    /// are prompted into the pane now, the agent then watched from the state it was in.
    fn take_hint(
        &mut self,
        p: &str,
        seen: Option<pane::Seen>,
        note: &dyn Fn(&str, &dyn std::fmt::Display),
    ) {
        let hint = match read_regular(&self.hint) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return,
            read => read
                .map_err(|e| e.to_string())
                .and_then(|s| TurnHint::parse(&s).map_err(|e| e.to_string())),
        };
        let hint = match hint {
            Ok(h) => h,
            Err(e) => return note("turn hint", &e),
        };
        self.grace_secs = hint.grace_secs;
        // a working or blocked agent is not prompted, as the coordinator never prompted one: the mail waits for it
        if !seen.is_some_and(|s| s.settled) {
            return;
        }
        let Some((text, upto)) = pane::mail(&hint.mail, self.upto) else {
            return;
        };
        if let Err(e) = self.send(p, &text) {
            return note("mail", &e);
        }
        self.upto = upto;
        self.watch = Some(pane::TurnWatch::new(seen.map_or(0, |s| s.seq)));
    }

    /// Prompts `input` into the pane ([`Herdr::prompt`]), a long one through [`pane::INPUT_FILE`].
    fn send(&self, p: &str, input: &str) -> Result<(), String> {
        let (long, text) = pane::prompt(input);
        if let Some(long) = long {
            write_home(
                &home_file(self.home, pane::INPUT_FILE),
                long.as_bytes(),
                owner(self.home)?,
            )?;
        }
        self.herdr.prompt(p, &text)
    }

    /// Prompts the turn's input once the agent draws its prompt box and Herdr calls it idle, as the named workers'
    /// first prompt was sent.
    fn first_prompt(&mut self, p: &str) -> Result<(), String> {
        self.herdr.call(
            &[
                "pane",
                "wait-output",
                p,
                "--match",
                pane::READY_TEXT,
                "--source",
                "visible",
                "--timeout",
                "120000",
            ],
            Duration::from_secs(120),
        )?;
        self.herdr.call(
            &["agent", "wait", p, "--until", "idle", "--timeout", "30000"],
            Duration::from_secs(30),
        )?;
        let before = self.herdr.seen(p)?.map_or(0, |s| s.seq);
        self.from = Some(
            transcript_of(self.home, self.uuid)
                .map(|t| read_regular_up_to(&t, TRANSCRIPT_LIMIT).map(|s| pane::count(&s)))
                .transpose()
                .map_err(|e| format!("transcript: {e}"))?
                .unwrap_or(0),
        );
        self.send(p, self.input)?;
        self.watch = Some(pane::TurnWatch::new(before));
        Ok(())
    }
}

/// The uid and gid that own the docked tree's `home`.
fn owner(home: &Path) -> Result<(u32, u32), String> {
    use std::os::unix::fs::MetadataExt as _;
    home.symlink_metadata()
        .map(|m| (m.uid(), m.gid()))
        .map_err(|e| format!("{}: {e}", home.display()))
}

/// The host path of a file the guest names under the session's HOME, `home` being the docked tree's.
fn home_file(home: &Path, guest_path: &str) -> PathBuf {
    home.join(
        guest_path
            .strip_prefix(SESSION_HOME)
            .unwrap_or(guest_path)
            .trim_start_matches('/'),
    )
}

/// Whether a subagent the session `uuid`'s agent started since `since` still runs ([`pane::subagent_running`]), by
/// its meta in the transcript directory under the docked tree's `home`. An older meta is a turn's that was closed
/// with it running, which no process carries on.
fn subagents(home: &Path, uuid: &str, since: SystemTime) -> bool {
    let Ok(projects) = fs::read_dir(home.join(".claude").join("projects")) else {
        return false;
    };
    projects
        .filter_map(Result::ok)
        .filter_map(|d| fs::read_dir(d.path().join(uuid).join("subagents")).ok())
        .flat_map(|d| d.filter_map(Result::ok))
        .any(|e| {
            let p = e.path();
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("agent-") && n.ends_with(".meta.json"))
                && p.symlink_metadata()
                    .and_then(|m| m.modified())
                    .is_ok_and(|t| t >= since)
                && read_regular(&p).is_ok_and(|m| pane::subagent_running(&m))
        })
}

/// The session's transcript in the docked tree's `home`, if Claude has written one.
fn transcript_of(home: &Path, uuid: &str) -> Option<PathBuf> {
    fs::read_dir(home.join(".claude").join("projects"))
        .ok()?
        .filter_map(Result::ok)
        .map(|d| d.path().join(format!("{uuid}.jsonl")))
        .find(|p| p.symlink_metadata().is_ok_and(|m| m.is_file()))
}

/// Readies the docked tree's `home` for the turn's interactive agent: no stale terminal socket, and the startup
/// dialogs a named worker's home has accepted ([`pane::accept_dialogs`]).
fn prepare_home(home: &Path) -> Result<(), String> {
    let owner = owner(home)?;
    let socket = home_file(home, agent::AGENT_SOCKET);
    match fs::remove_file(&socket) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", socket.display()));
        }
        _ => {}
    }
    let state = home.join(".claude.json");
    let current = match read_regular(&state) {
        Ok(s) => Some(Some(s)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Some(None),
        // not a regular file, or too big: left as it is
        Err(_) => None,
    };
    if let Some(seeded) = current.and_then(|c| pane::accept_dialogs(c.as_deref())) {
        write_home(&state, seeded.as_bytes(), owner)?;
    }
    Ok(())
}

/// Writes `bytes` to `path` in a directory the guest user owns, as root: a new file beside it (created, never
/// opened through a link), owned by `owner` and 0600, renamed over it, so no link the agent left is followed.
fn write_home(path: &Path, bytes: &[u8], (uid, gid): (u32, u32)) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let err = |e: io::Error| format!("{}: {e}", path.display());
    let tmp = path.with_extension("exec-pool");
    match fs::remove_file(&tmp) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(err(e)),
        _ => {}
    }
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(err)?;
    io::Write::write_all(&mut f, bytes).map_err(err)?;
    std::os::unix::fs::fchown(&f, Some(uid), Some(gid)).map_err(err)?;
    fs::rename(&tmp, path).map_err(err)
}

/// The slot's dock for a session turn, and the mark that tells the runner work is in it that is not on its remote.
struct Dock<'a> {
    on_host: workspace::Dock,
    busy: PathBuf,
    /// The runner's runtime directory, where the transcript comes from and goes to.
    runtime: PathBuf,
    slot: &'a str,
    /// `cp`, `find`, `install` and `cat`: the store paths of the relink, the transcript probe and its copy in and out;
    /// `dtach`, the agent's terminal.
    cp: String,
    find: String,
    install: String,
    cat: String,
    dtach: String,
    /// The host user's Herdr the turn's pane is opened in; `None` (the pool's `sessionSurface = "headless"`): the
    /// turn runs in Claude's print mode, with no pane.
    herdr: Option<Herdr>,
    /// The node-exporter textfile directory the park's failed pushes are counted in.
    counts: Option<PathBuf>,
}

impl<'a> Dock<'a> {
    /// The dock of `slot`, whose run directories are in `slot_dir`, as the helper's unit configures it.
    fn from_env(slot: &'a str, slot_dir: &Path) -> Result<Self, String> {
        let [sessions, runtime, cp, find, install, cat] = vars([
            "EXEC_POOL_SESSIONS",
            "EXEC_POOL_RUNTIME",
            "EXEC_POOL_CP",
            "EXEC_POOL_FIND",
            "EXEC_POOL_INSTALL",
            "EXEC_POOL_CAT",
        ])?;
        Ok(Self {
            on_host: workspace::Dock::new(Path::new(&sessions), slot),
            busy: slot_dir.join(DOCK_BUSY),
            runtime: PathBuf::from(runtime),
            slot,
            cp,
            find,
            install,
            cat,
            dtach: var("EXEC_POOL_DTACH")?,
            herdr: Herdr::from_env(slot)?,
            counts: std::env::var_os("EXEC_POOL_TEXTFILE").map(PathBuf::from),
        })
    }

    /// What the mark says while the turn's work is in the dock and not on its remote, and how an operator frees it.
    fn held(&self, m: &Manifest, why: &str) -> String {
        format!(
            "the work of task {}'s turn is in the dock at {}, not on its remote: {why}; push it from there or archive \
             it, then rm {} and the slot's quarantine marker",
            m.task.id,
            self.on_host.cur().display(),
            self.busy.display()
        )
    }

    /// Makes the dock afresh for the turn, owned as the slot home is, with the transcript the runner put beside the
    /// manifest. The dock is marked first and stays marked until the turn's work is on its remote, so whatever stops
    /// this helper in between leaves the runner to quarantine the slot with the work kept; a dock still marked is
    /// refused.
    fn open(&self, m: &Manifest, slot_home: &Path) -> Result<(), String> {
        use std::os::unix::fs::MetadataExt as _;
        if let Ok(why) = fs::read_to_string(&self.busy) {
            return Err(format!("the dock is still marked: {}", why.trim_end()));
        }
        let home = slot_home
            .symlink_metadata()
            .map_err(|e| format!("{}: {e}", slot_home.display()))?;
        let transcript = match m.session.as_ref().and_then(|s| s.transcript.as_ref()) {
            Some(_) => Some(
                read_bytes(&self.runtime.join(TRANSCRIPT_IN), TRANSCRIPT_BYTES)
                    .map_err(|e| format!("{TRANSCRIPT_IN}: {e}"))?,
            ),
            None => None,
        };
        fs::write(
            &self.busy,
            format!("{}\n", self.held(m, "its turn runs in it")),
        )
        .map_err(|e| format!("{}: {e}", self.busy.display()))?;
        self.on_host
            .make((home.uid(), home.gid()), transcript.as_deref())
            .map_err(|e| e.to_string())
    }

    /// [`Dock::open`], then where the last park left the session's work, which the turn's clone goes back to; whether
    /// the dock was made, and that.
    fn ready(
        &self,
        (m, slot_home, guest): (&Manifest, &Path, &Guest),
        tools: (&str, &str),
        dir: (&Path, &File),
        note: &dyn Fn(&str, &dyn std::fmt::Display),
    ) -> (bool, Option<Resume>) {
        if let Err(e) = self.open(m, slot_home) {
            note("no dock", &e);
            return (false, None);
        }
        let resume = guest
            .resume(m, tools, dir)
            .inspect_err(|e| note("not listed", e))
            .ok();
        (true, resume)
    }

    /// After a turn its agent reached: its transcript to the runner, then its work to the remote, each into `result`
    /// ([`ExecResult::transcript`], [`ExecResult::parked_at`]), or why not ([`ExecResult::unkept`]). The push is made
    /// whatever became of the transcript, so the work is not left behind for it.
    fn park(
        &self,
        (m, ws, guest): (&Manifest, &Workspace, &Guest),
        tools: (&str, &str),
        (dir, err): (&Path, &File),
        result: &mut ExecResult,
    ) {
        let note = |what: &str, e: &dyn std::fmt::Display| {
            let _ = io::Write::write_all(
                &mut &*err,
                format!("exec-pool-exec: {what}: {e}\n").as_bytes(),
            );
        };
        let mut unkept = Vec::new();
        match self.take_transcript(m, guest, (dir, err)) {
            Ok(t) => result.transcript = t,
            Err(e) => {
                note("transcript", &e);
                unkept.push(e);
            }
        }
        match self.push((m, ws, guest), tools, (dir, err)) {
            Ok(at) => result.parked_at = Some(at),
            Err(e) => unkept.push(e),
        }
        result.unkept = (!unkept.is_empty()).then(|| unkept.join("; "));
    }

    /// The turn's transcript, copied out by the guest as its user (so a link the agent left reaches nothing it could
    /// not read itself) into the runner's runtime directory as [`TRANSCRIPT_OUT`], the runner's, 0600; its project,
    /// `None` when the agent wrote none.
    fn take_transcript(
        &self,
        m: &Manifest,
        guest: &Guest,
        (dir, err): (&Path, &File),
    ) -> Result<Option<String>, String> {
        use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
        let session = m
            .session
            .as_ref()
            .ok_or("a one-shot manifest has no transcript")?;
        let Some(path) = guest.transcript(&self.find, session, (dir, err))? else {
            return Ok(None);
        };
        let project = path
            .strip_prefix(&format!("{SESSION_HOME}/.claude/projects/"))
            .and_then(|p| p.strip_suffix(&format!("/{}.jsonl", session.uuid)))
            .filter(|p| Transcript::valid_project(p))
            .ok_or_else(|| format!("a transcript at {path:?}"))?
            .to_owned();
        let io = |e: io::Error| format!("{TRANSCRIPT_OUT}: {e}");
        let tmp = self.runtime.join(format!("{TRANSCRIPT_OUT}.tmp"));
        let _ = fs::remove_file(&tmp);
        let out = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(io)?;
        let keep = u64::try_from(TRANSCRIPT_BYTES).map_or(u64::MAX, |n| n.saturating_add(1));
        let argv = [self.cat.clone(), "--".to_owned(), path];
        let end = guest
            .step_watched(
                ("exec-pool-transcript-out", false),
                &argv,
                (PREPARE_TIMEOUT, (&out, keep), err),
                None,
                &mut never,
            )
            .map_err(io)?;
        let size = out.metadata().map_err(io)?.len();
        let owner = self.runtime.metadata().map_err(io)?;
        let taken = match end.exit_code {
            Some(0) if size < keep => {
                std::os::unix::fs::lchown(&tmp, Some(owner.uid()), Some(owner.gid()))
                    .and_then(|()| fs::rename(&tmp, self.runtime.join(TRANSCRIPT_OUT)))
                    .map_err(io)
            }
            Some(0) => Err(format!(
                "the transcript is over the queue's {TRANSCRIPT_BYTES} bytes"
            )),
            other => Err(format!("exec-pool-transcript-out ended with {other:?}")),
        };
        if taken.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        taken.map(|()| Some(project))
    }

    /// The turn's work to its remote ([`Dock::push_once`]), tried again with a growing pause while [`PARK_PUSH_WAIT`]
    /// lasts and no cancel names the attempt (a drain does not stop it: the work is what a drain must keep). Every
    /// failure is noted and counted in the slot's textfile, `exec_pool_park_push_failures_total`.
    fn push(
        &self,
        (m, ws, guest): (&Manifest, &Workspace, &Guest),
        tools: (&str, &str),
        (dir, err): (&Path, &File),
    ) -> Result<ParkedAt, String> {
        let t = Instant::now();
        let mut pause = PARK_PUSH_PAUSE;
        loop {
            let e = match Self::push_once((m, ws, guest), tools, (dir, err)) {
                Ok(at) => return Ok(at),
                Err(e) => e,
            };
            let _ = io::Write::write_all(
                &mut &*err,
                format!("exec-pool-exec: park push: {e}\n").as_bytes(),
            );
            if let Some(d) = &self.counts {
                let file = d.join(format!("exec-pool-park-{}.prom", self.slot));
                if let Err(e) = textfile::bump(
                    &file,
                    PARK_PUSH_FAILURES,
                    &format!("slot=\"{}\"", self.slot),
                    1,
                ) {
                    eprintln!("exec-pool-exec: {}: {e}", file.display());
                }
            }
            if guest.cancel_asked() || t.elapsed().saturating_add(pause) > PARK_PUSH_WAIT {
                return Err(format!("the park's push: {e}"));
            }
            thread::sleep(pause);
            pause = pause.saturating_mul(2).min(PARK_PUSH_PAUSE_MAX);
        }
    }

    /// One try at the park's [`Plan`]: the snapshot commit pushed to [`snapshot::wip_ref`], or that ref removed, or
    /// nothing; where the remote then holds the turn's work.
    fn push_once(
        (m, ws, guest): (&Manifest, &Workspace, &Guest),
        (git, env): (&str, &str),
        dir: (&Path, &File),
    ) -> Result<ParkedAt, String> {
        let g = Git {
            env,
            git,
            checkout: SESSION_WORK,
        };
        let branch = agent::branch(&m.task).map_err(|e| e.to_string())?;
        let wip = snapshot::wip_ref(&m.task).map_err(|e| e.to_string())?;
        let run = |unit: &str, argv: Vec<String>| guest.output(unit, &argv, dir);
        let heads = run("exec-pool-head", g.head())?;
        let (head, head_tree) = heads
            .split_once('\n')
            .ok_or_else(|| format!("rev-parse printed {heads:?}"))?;
        let listing = run(
            "exec-pool-listed",
            g.list(&m.task.source.repo, &branch, &wip),
        )?;
        let [read, add, write] = g.tree(&format!("{}/snapshot.index", ws.tmp()));
        run("exec-pool-index", read)?;
        run("exec-pool-add", add)?;
        let tree = run("exec-pool-write-tree", write)?;
        let on = listed(&listing, &format!("refs/heads/{branch}"));
        // what the remote shows after the push, listed as before: a push the checkout's config sent elsewhere fails
        let check = |want: Option<&str>| {
            let after = run(
                "exec-pool-landed",
                g.list(&m.task.source.repo, &branch, &wip),
            )?;
            if landed(&after, &wip, want) {
                Ok(())
            } else {
                Err(format!(
                    "the remote shows {wip} at {:?}, not {want:?}",
                    listed(&after, &wip)
                ))
            }
        };
        let at_branch = ParkedAt {
            name: format!("refs/heads/{branch}"),
            commit: on.clone(),
        };
        match plan(
            (on.as_deref(), listed(&listing, &wip).as_deref()),
            (head, head_tree),
            &tree,
        ) {
            Plan::Clean => Ok(at_branch),
            Plan::Clear => {
                run("exec-pool-push", g.push(&m.task.source.repo, None, &wip))?;
                check(None).map(|()| at_branch)
            }
            Plan::Snapshot => {
                let message = format!(
                    "pool: what task {} left uncommitted at its park (lease epoch {})\n\nA system checkpoint for \
                     the session's next turn, never merged.",
                    m.task.id, m.lease_epoch
                );
                let commit = run("exec-pool-snapshot", g.commit(&tree, &message))?;
                run(
                    "exec-pool-push",
                    g.push(&m.task.source.repo, Some(&commit), &wip),
                )?;
                check(Some(&commit))?;
                Ok(ParkedAt {
                    name: wip,
                    commit: Some(commit),
                })
            }
        }
    }

    /// The turn after its preparing: its agent step, in the slot's Herdr pane ([`PaneTurn`]) or with no Herdr in
    /// Claude's print mode, and the verdict from its transcript. A turn with no agent step stays in preparing, so it
    /// goes back to the queue; one whose pane or prompt never reached the agent parks with its input unread
    /// ([`parks_undelivered`]).
    fn turn(
        &self,
        (m, ws, guest): (&Manifest, &Workspace, &Guest),
        env: &str,
        (bounds, dir, out, err): ((Duration, Instant), &Path, &File, &File),
        result: &mut ExecResult,
    ) {
        let note = note_to(err);
        if m.session.is_none() {
            result.failed_step = Some("turn".to_owned());
            note("no turn", &"a one-shot manifest has no turn");
            return;
        }
        self.agent_turn((m, ws, guest), env, (bounds, dir, out, err), result, &note);
    }

    /// The turn's agent step and its pane; `m`'s input is all the turn has to deliver.
    fn agent_turn(
        &self,
        (m, ws, guest): (&Manifest, &Workspace, &Guest),
        env: &str,
        (bounds, dir, out, err): ((Duration, Instant), &Path, &File, &File),
        result: &mut ExecResult,
        note: &dyn Fn(&str, &dyn std::fmt::Display),
    ) {
        let Some(session) = &m.session else {
            return;
        };
        let Some(herdr) = &self.herdr else {
            match guest.turn(m, ws, (None, env, &self.find), (dir, err)) {
                Ok((run, _)) => {
                    guest.steps(vec![run], bounds, (out, err), result, &mut never);
                }
                Err(e) => {
                    result.failed_step = Some("turn".to_owned());
                    note("no turn", &e);
                }
            }
            return;
        };
        if let Err(e) = herdr.running() {
            result.failed_step = Some("herdr".to_owned());
            note("herdr", &e);
            return;
        }
        let home = self.on_host.cur().join("home");
        let input = agent::turn_input(&m.task, &session.input, agent::Turn::Start);
        let run = guest.turn(m, ws, (Some(&self.dtach), env, &self.find), (dir, err));
        let prepared = run.and_then(|(run, turn)| {
            let input = match turn {
                agent::Turn::Start => input.map_err(|e| e.to_string())?,
                agent::Turn::Resume => session.input.clone(),
            };
            prepare_home(&home)?;
            Ok((run, input))
        });
        let (run, input) = match prepared {
            Ok(p) => p,
            Err(e) => {
                result.failed_step = Some("turn".to_owned());
                note("no turn", &e);
                return;
            }
        };
        let hint = guest.cancel.0.with_file_name(TURN_HINT);
        let step = (guest.slot.as_str(), run.unit);
        let mut pane = PaneTurn::new(herdr, (m, hint), (&home, step), &session.uuid, &input);
        guest.steps(vec![run], bounds, (out, err), result, &mut || {
            pane.poll(note)
        });
        for w in &pane.opened {
            herdr.close(w);
        }
        herdr.close_slots();
        if pane.idle && result.drained && !result.timed_out {
            // drained in its pause, the agent had ended its turn: nothing of it to continue
            result.drained = false;
            pane.ended = true;
        }
        result.upto = Some(pane.upto);
        let stopped = result.timed_out || result.cancelled || result.drained;
        if pane.ended && !stopped {
            // the agent was waiting for input and was closed: the turn ended, whatever its close's exit
            result.exit_code = Some(0);
        }
        let transcript = transcript_of(&home, &session.uuid)
            .map(|p| read_regular_up_to(&p, TRANSCRIPT_LIMIT))
            .transpose()
            .inspect_err(|e| note("transcript", e))
            .ok()
            .flatten()
            .unwrap_or_default();
        let (line, ran) = pane::verdict(&transcript, pane.from.unwrap_or(usize::MAX), pane.ended);
        if pane.from.is_none() || (!ran && !stopped) {
            // nothing of the turn's input reached the agent: nothing it could have done
            result.stage = Stage::Prepare;
            result.failed_step = Some("prompt".to_owned());
            note("prompt", &"the turn's input never reached the agent");
            return;
        }
        if let Err(e) = io::Write::write_all(&mut &*out, format!("\n{line}\n").as_bytes()) {
            note("verdict", &e);
        }
    }

    /// The wake the turn's agent asked for with `pool-wait`, read from the dock's HOME once its steps are gone and
    /// removed from it; a file that is not a regular one or does not parse is dropped and noted, never failing the
    /// park.
    fn take_wake(&self, note: &dyn Fn(&str, &dyn std::fmt::Display)) -> Option<Wake> {
        let path = self.on_host.cur().join("home").join(wake::FILE);
        let read = match read_regular(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return None,
            read => read,
        };
        if let Err(e) = fs::remove_file(&path) {
            note("pool-wait", &e);
        }
        read.map_err(|e| e.to_string())
            .and_then(|s| Wake::parse(s.trim_end()).map_err(|e| e.to_string()))
            .inspect_err(|e| note("pool-wait dropped", e))
            .ok()
    }

    /// Once the turn's steps are gone from the guest: its wake into `result`, then the dock removed and its mark
    /// cleared when nothing in it is missing from the remote (its park pushed, or its agent never ran). Otherwise, a
    /// step still in the guest included, the dock is kept and marked, so the runner quarantines the slot rather than
    /// reuse it.
    fn close(
        &self,
        m: &Manifest,
        guest: &Guest,
        note: &dyn Fn(&str, &dyn std::fmt::Display),
        result: &mut ExecResult,
    ) {
        let ran = result.stage == Stage::Run;
        let held = if guest.steps_gone() {
            if ran {
                result.wake = self.take_wake(note);
            }
            result
                .unkept
                .clone()
                .filter(|_| ran)
                .map_or_else(|| self.on_host.clear().map_err(|e| e.to_string()), Err)
        } else {
            Err("a step of the turn is still in the guest".to_owned())
        };
        match held {
            Ok(()) => {
                let _ = fs::remove_file(&self.busy);
            }
            Err(why) => {
                note("dock kept", &why);
                let _ = fs::write(&self.busy, format!("{}\n", self.held(m, &why)));
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

/// What the helper starts a run with: its manifest, bound, run directory and output files, and the slot's guest.
struct Begun {
    manifest: Manifest,
    timeout: Duration,
    slot_dir: PathBuf,
    dir: PathBuf,
    out: File,
    err: File,
    guest: Guest,
}

/// Reads the slot's manifest and makes the run's directory, which must not exist yet.
fn begin(slot: &str) -> Result<Begun, String> {
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
        cancel: (
            runtime.join(CANCEL),
            manifest.cancel_token(),
            manifest.drain_token(),
        ),
        env: env.iter().map(|(k, v)| format!("{k}={v}")).collect(),
        log: turn_log::Writer::create(&dir, LOG_BYTES)
            .inspect_err(|e| eprintln!("exec-pool-exec: turn log: {e}"))
            .ok()
            .map(Arc::new),
    };
    Ok(Begun {
        manifest,
        timeout,
        slot_dir,
        dir,
        out,
        err,
        guest,
    })
}

/// What a helper notes in the run's stderr file, as `exec-pool-exec: <what>: <e>`.
fn note_to(err: &File) -> impl Fn(&str, &dyn std::fmt::Display) + '_ {
    move |what, e| {
        let _ = io::Write::write_all(
            &mut &*err,
            format!("exec-pool-exec: {what}: {e}\n").as_bytes(),
        );
    }
}

fn exec(slot: &str) -> Result<(), String> {
    let Begun {
        manifest,
        timeout,
        slot_dir,
        dir,
        out,
        err,
        guest,
    } = begin(slot)?;
    let mut result = ExecResult::begun(&manifest);
    let t = Instant::now();
    let memory = MemoryWatch::start(slot);
    let guest_home = var("EXEC_POOL_GUEST_HOME")?;
    let ws = manifest
        .workspace(&guest_home)
        .map_err(|e| format!("manifest: {e}"))?;
    let [git, env, mkdir, name, email] = vars([
        "EXEC_POOL_GIT",
        "EXEC_POOL_ENV",
        "EXEC_POOL_MKDIR",
        "EXEC_POOL_GIT_NAME",
        "EXEC_POOL_GIT_EMAIL",
    ])?;
    let note = note_to(&err);
    let slot_home = PathBuf::from(var("EXEC_POOL_SLOT_HOME")?);
    // a home an earlier attempt ran in is refused before anything runs in it: the attempt goes back to the queue
    let admitted = admit_home(&slot_home, &slot_dir.join(LAST_HOME))
        .inspect_err(|e| note("not admitted", e))
        .is_ok();
    // a session turn runs in the slot's dock, made afresh for it; all it reads is read before, and nothing between
    // its making and its close returns early
    let dock = match &manifest.session {
        Some(_) => Some(Dock::from_env(slot, &slot_dir)?),
        None => None,
    };
    let (opened, resume) = match (&dock, admitted) {
        (Some(d), true) => d.ready(
            (&manifest, &slot_home, &guest),
            (&git, &env),
            (&dir, &err),
            &note,
        ),
        _ => (false, None),
    };
    let tools = (git.as_str(), env.as_str(), mkdir.as_str());
    let steps = match (&dock, &resume) {
        (None, _) => manifest.steps(&ws, tools, (&name, &email)),
        (Some(d), Some(r)) => manifest.session_steps(
            &ws,
            tools,
            (&name, &email),
            (r, relink(&d.cp, &guest_home), &d.install),
        ),
        (Some(_), None) => Ok(Vec::new()),
    }
    .inspect_err(|e| note("manifest", e))
    .ok()
    .filter(|s| !s.is_empty());
    let runs = admitted && (manifest.session.is_none() || resume.is_some());
    // an agent task's branch as it was, so an earlier run's push is not taken for this one's
    let agentic = manifest.task.command.agent != Agent::None;
    let before = if runs && agentic {
        guest.remote_head(&manifest, (&git, &env), (&dir, "pushed-before"), &err)
    } else {
        Listed::Unknown
    };
    if let (true, Some(steps)) = (runs, steps) {
        let prepared = guest.steps(steps, (timeout, t), (&out, &err), &mut result, &mut never);
        if let (Some(d), true) = (&dock, prepared) {
            d.turn(
                (&manifest, &ws, &guest),
                &env,
                ((timeout, t), &dir, &out, &err),
                &mut result,
            );
        }
        // whatever the run's end: a push may have landed before it failed
        if result.stage == Stage::Run && agentic {
            guest.hand_back(
                (&manifest, &ws),
                (&git, &env),
                &before,
                (&dir, &err),
                &mut result,
            );
        }
        if let (Some(d), Stage::Run) = (&dock, result.stage) {
            d.park(
                (&manifest, &ws, &guest),
                (&git, &env),
                (&dir, &err),
                &mut result,
            );
        }
    }
    if let (Some(d), true) = (&dock, opened) {
        d.close(&manifest, &guest, &note, &mut result);
    }
    if result.stage == Stage::Prepare {
        result.prepare_ms = ms(t);
        let ready = (admitted, dock.is_some(), opened, resume.is_some());
        failed_preparing(slot, &mut result, ready);
    }
    MemoryWatch::finish(memory, slot, &mut result, &note);
    write_result(slot, &dir, result)
}

/// The slot's OOM kills as a run began: its cgroup on the host (`EXEC_POOL_SLOT_CGROUP`), its `memory.events`
/// `oom_kill` count then, and when.
struct MemoryWatch {
    cgroup: String,
    kills: u64,
    since: SystemTime,
}

impl MemoryWatch {
    /// `None` without the variable or a count to read: the run's kills go uncounted. The slot's counter is written
    /// at 0 first, so its first kill after a boot is an increase.
    fn start(slot: &str) -> Option<Self> {
        let cgroup = std::env::var("EXEC_POOL_SLOT_CGROUP").ok()?;
        let kills = Self::kills(&cgroup)?;
        Self::count(slot, 0);
        Some(Self {
            cgroup,
            kills,
            since: SystemTime::now(),
        })
    }

    fn kills(cgroup: &str) -> Option<u64> {
        let events = fs::read_to_string(format!("/sys/fs/cgroup{cgroup}/memory.events")).ok()?;
        events
            .lines()
            .find_map(|l| l.strip_prefix("oom_kill "))
            .and_then(|n| n.trim().parse().ok())
    }

    /// Records in `result` the kills since the run began and the names the kernel's log gives them, and counts them
    /// in the slot's textfile, `exec_pool_memory_kills_total{slot}`. A guest restarted since (a lower count) counts
    /// none.
    fn finish(
        watch: Option<Self>,
        slot: &str,
        result: &mut ExecResult,
        note: &dyn Fn(&str, &dyn std::fmt::Display),
    ) {
        let Some((watch, now)) = watch.and_then(|w| Self::kills(&w.cgroup).map(|now| (w, now)))
        else {
            return;
        };
        let n = now.saturating_sub(watch.kills);
        if n == 0 {
            return;
        }
        result.oom_kills = Some(n);
        let since = watch
            .since
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let kmsg = Command::new("journalctl")
            .args([
                "-k",
                "-q",
                "-o",
                "cat",
                "--no-pager",
                &format!("--since=@{since}"),
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output();
        match kmsg {
            Ok(o) => {
                result.oom_victims =
                    oom_victims(&String::from_utf8_lossy(&o.stdout), &watch.cgroup);
            }
            Err(e) => note("kernel log", &e),
        }
        note(
            "memory kill",
            &format!(
                "the OOM killer killed {n} process(es) of the slot: {:?}",
                result.oom_victims
            ),
        );
        Self::count(slot, n);
    }

    fn count(slot: &str, n: u64) {
        if let Some(dir) = std::env::var_os("EXEC_POOL_TEXTFILE") {
            let file = PathBuf::from(dir).join(format!("exec-pool-memory-{slot}.prom"));
            if let Err(e) = textfile::bump(&file, MEMORY_KILLS, &format!("slot=\"{slot}\""), n) {
                eprintln!("exec-pool-exec: {}: {e}", file.display());
            }
        }
    }
}

/// Names the step a run that never reached its agent failed at when no prepare step did, from `ready` (the home
/// admitted, a session, its dock made, its remote listed): refused the home, no dock made, the remote not listed, or no
/// steps; and counts it in the slot's textfile,
/// `exec_pool_prepare_failures_total{step}`, if this host has one: the step is a bounded name, never the task's. A run
/// stopped by a cancel or a drain did not fail.
fn failed_preparing(slot: &str, result: &mut ExecResult, ready: (bool, bool, bool, bool)) {
    if result.cancelled || result.drained {
        return;
    }
    let unready = match ready {
        (false, ..) => "admit",
        (true, true, false, _) => "dock",
        (true, true, true, false) => "list",
        _ => "manifest",
    };
    let step = result.failed_step.get_or_insert_with(|| unready.to_owned());
    if let Some(dir) = std::env::var_os("EXEC_POOL_TEXTFILE") {
        let file = PathBuf::from(dir).join(format!("exec-pool-prepare-{slot}.prom"));
        let counted = textfile::bump(&file, PREPARE_FAILURES, &format!("step=\"{step}\""), 1);
        if let Err(e) = counted {
            eprintln!("exec-pool-exec: {}: {e}", file.display());
        }
    }
}

/// Completes `result` with whether the slot's guest is still up and the ends of the run's output, and writes it for
/// the runner.
fn write_result(slot: &str, dir: &Path, mut result: ExecResult) -> Result<(), String> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pane_waiting_on_its_background_command_is_not_parked_but_its_turn_limit_still_cuts() {
        let limit_secs = 1800;
        let seen = Some(pane::Seen {
            settled: true,
            seq: 2,
        });
        // polls every 2 s of an agent Herdr shows idle since the prompt: the step's watch, the time limit's start
        let run = |jobs: bool| {
            let mut w = pane::TurnWatch::new(1);
            let t0 = Instant::now();
            let mut since = t0;
            for ms in (0..=3_600_000_u64).step_by(2000) {
                let idle = w.idle_ms(seen, jobs, ms);
                if pane::parks(idle, GRACE_SECS, false) {
                    return ("parked", ms);
                }
                let watched = if idle.is_some() {
                    Watch::Idle
                } else {
                    Watch::Busy
                };
                let cut;
                (since, cut) = limit(
                    since,
                    watched,
                    t0 + Duration::from_millis(ms),
                    Duration::from_secs(limit_secs),
                );
                if cut {
                    return ("cut", ms);
                }
            }
            ("running", 0)
        };
        assert_eq!(run(false), ("parked", GRACE_SECS * 1000));
        assert_eq!(run(true), ("cut", limit_secs * 1000 + 2000));
    }

    #[test]
    fn a_subagent_started_this_turn_keeps_the_agent_busy_until_it_finishes() {
        let home = std::env::temp_dir().join(format!("exec-pool-subagents-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        let uuid = "c3d69fdc-2343-4532-a7dc-46ef64b5040a";
        let dir = home
            .join(".claude/projects/-session-cur-work")
            .join(uuid)
            .join("subagents");
        fs::create_dir_all(&dir).unwrap();
        let since = SystemTime::now() - Duration::from_secs(1);
        assert!(!subagents(&home, uuid, since));
        let meta = dir.join("agent-a1.meta.json");
        fs::write(
            &meta,
            r#"{"agentType":"general-purpose","requestShape":"background"}"#,
        )
        .unwrap();
        fs::write(dir.join("agent-a1.jsonl"), "{}\n").unwrap();
        assert!(subagents(&home, uuid, since));
        // another session's, or one from before the turn, does not count
        assert!(!subagents(&home, "another", since));
        assert!(!subagents(
            &home,
            uuid,
            SystemTime::now() + Duration::from_secs(60)
        ));
        fs::write(
            &meta,
            r#"{"agentType":"general-purpose","requestShape":"background","finished":true}"#,
        )
        .unwrap();
        assert!(!subagents(&home, uuid, since));
        // a link is not read
        let link = dir.join("agent-a2.meta.json");
        std::os::unix::fs::symlink(home.join("elsewhere.json"), &link).unwrap();
        fs::write(home.join("elsewhere.json"), "{}").unwrap();
        assert!(!subagents(&home, uuid, since));
        fs::remove_dir_all(&home).unwrap();
    }

    /// A herdr that answers as Herdr 0.9.5 does: one JSON object for `workspace` and `agent list`, nothing at all
    /// for `pane run` and `pane send-keys`, an error as JSON on stderr with exit 1; each call's argv logged.
    fn fake(name: &str, pane_run_fails: bool) -> (Herdr, PathBuf) {
        fake_with(name, pane_run_fails, ":")
    }

    /// [`fake`], `agent prompt` answering with the shell snippet `prompt`.
    fn fake_with(name: &str, pane_run_fails: bool, prompt: &str) -> (Herdr, PathBuf) {
        let log =
            std::env::temp_dir().join(format!("exec-pool-herdr-{name}-{}", std::process::id()));
        let _ = fs::remove_file(&log);
        let fail = if pane_run_fails {
            r#"printf '%s' '{"error":{"code":"pane_not_found","message":"pane w1:p1 not found"},"id":"cli:pane:run"}' >&2; exit 1"#
        } else {
            ":"
        };
        let script = format!(
            r#"printf '%s\n' "$*" >> '{}'
case "$1 $2" in
"workspace create") printf '%s' '{{"id":"cli:workspace:create","result":{{"root_pane":{{"pane_id":"w1:p1","workspace_id":"w1"}},"type":"workspace_created","workspace":{{"label":"pool9 k","workspace_id":"w1"}}}}}}' ;;
"workspace list") printf '%s' '{{"id":"cli:workspace:list","result":{{"type":"workspace_list","workspaces":[{{"label":"pool9 k","workspace_id":"w7"}},{{"label":"pool10 k","workspace_id":"w8"}}]}}}}' ;;
"workspace close") printf '%s' '{{"id":"cli:workspace:close","result":{{"type":"ok"}}}}' ;;
"agent list") printf '%s' '{{"id":"cli:agent:list","result":{{"agents":[],"type":"agent_list"}}}}' ;;
"pane run") {fail} ;;
"agent prompt") {prompt} ;;
"agent send-keys") printf '%s' '{{"id":"cli:agent:send-keys","result":{{"type":"ok"}}}}' ;;
esac"#,
            log.display()
        );
        let herdr = Herdr {
            argv: vec!["/bin/sh".into(), "-c".into(), script, "herdr".into()],
            attach: "/run/current-system/sw/bin/pool-pool9 turn".to_owned(),
            slot: "pool9".to_owned(),
        };
        (herdr, log)
    }

    fn calls(log: &Path) -> Vec<String> {
        fs::read_to_string(log)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn a_pane_run_that_prints_nothing_opens_the_pane() {
        let (herdr, log) = fake("open", false);
        assert_eq!(
            herdr.open("pool9 k").unwrap(),
            ("w1".to_owned(), "w1:p1".to_owned())
        );
        assert_eq!(
            herdr.call(&["pane", "send-keys", "w1:p1", "ctrl+c"], Duration::ZERO),
            Ok(Value::Null)
        );
        assert_eq!(herdr.seen("w1:p1"), Ok(None));
        assert_eq!(
            calls(&log),
            [
                "workspace list",
                "workspace close w7",
                "workspace create --label pool9 k --no-focus",
                "pane run w1:p1 /run/current-system/sw/bin/pool-pool9 turn",
                "pane send-keys w1:p1 ctrl+c",
                "agent list",
            ]
        );
    }

    #[test]
    fn a_workspace_whose_pane_could_not_attach_is_closed_again() {
        let (herdr, log) = fake("fail", true);
        let e = herdr.open("pool9 k").unwrap_err();
        assert!(e.contains("pane_not_found"), "{e}");
        assert_eq!(calls(&log).last().unwrap(), "workspace close w1");
    }

    #[test]
    fn a_refused_prompt_is_an_error_and_a_slow_one_gets_its_enter_again() {
        let err = |code: &str| {
            format!(
                r#"printf '%s' '{{"error":{{"code":"{code}","message":"m"}},"id":"cli:agent:prompt"}}' >&2; exit 1"#
            )
        };
        let (herdr, log) = fake_with("blocked", false, &err("agent_blocked"));
        assert!(herdr.prompt("w1:p1", "go").is_err());
        assert!(
            !calls(&log).iter().any(|c| c.starts_with("agent send-keys")),
            "no Enter into a dialog"
        );
        for code in ["timeout", "agent_prompt_stalled"] {
            let (herdr, log) = fake_with(code, false, &err(code));
            assert_eq!(herdr.prompt("w1:p1", "go"), Ok(()));
            assert_eq!(calls(&log).last().unwrap(), "agent send-keys w1:p1 Enter");
        }
        let (herdr, _) = fake_with(
            "prompted",
            false,
            r#"printf '%s' '{"id":"cli:agent:prompt","result":{"type":"ok"}}'"#,
        );
        assert_eq!(herdr.prompt("w1:p1", "go"), Ok(()));
    }
}
