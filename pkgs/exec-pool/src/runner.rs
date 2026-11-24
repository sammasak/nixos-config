//! What the pool runner (#652) and its slot-control helper agree on, and the runner's decisions.
//!
//! Apart from the host, so they are tested without one. The runner (`exec_pool`, the queue's peer role) claims an attempt, writes a
//! [`Manifest`] and starts `exec-pool-exec@<slot>`; that helper (root, no queue access) runs the task in the slot's
//! guest as its user and writes an [`ExecResult`]; the runner settles the attempt from it with [`decide`] and releases
//! the slot with `dev-env-reset@<slot>`. Each attempt runs in its own [`Workspace`], which that reset removes with the
//! home. A session task's lease is one turn ([`Session`]): its HOME and checkout are its tree, attached to the slot for
//! the turn, and the turn ends in a park ([`decide_turn`]), not a settle.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Read as _};
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::queue::QueueError;
use crate::wake::Wake;
use crate::workspace::{self, SESSION_HOME, SESSION_WORK, Workspace};
use crate::{
    Agent, CheckpointRef, Error, Outcome, ParkReason, Receipt, STORE, SchemaVersion, Settle,
    TaskSpec, agent, parse_versioned,
};

/// How much of each output stream the result carries; the host keeps up to [`CAPTURE_BYTES`] of it.
pub const TAIL_BYTES: usize = 2048;
/// The counter of runs that failed before their agent started, by step, and its help text.
pub const PREPARE_FAILURES: (&str, &str) = (
    "exec_pool_prepare_failures_total",
    "Runs that failed before their agent started, by the step they failed at.",
);
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
    /// A session task's turn; `None` for a one-shot task.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<Session>,
}

/// One turn of a session task, as its claim carries it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Session {
    /// The agent's session id, the queue's.
    pub uuid: String,
    /// What the turn tells the agent: the task's prompt on its first turn, the messages sent since on a later one.
    pub input: String,
    /// The last inbox message the input holds, handed back with the park.
    pub upto: i64,
    /// Where the last park left the tree; with one, the tree must exist, as the agent's session is in it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint: Option<CheckpointRef>,
}

/// One guest command of a run, under its transient unit's name; `limit_secs` bounds a quick one tighter than its
/// stage does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub stage: Stage,
    pub unit: &'static str,
    pub argv: Vec<String>,
    pub limit_secs: Option<u64>,
}

/// The bound of a quick step: a relink or the transcript probe.
pub const QUICK_SECS: u64 = 30;

const fn step(stage: Stage, unit: &'static str, argv: Vec<String>) -> Step {
    Step {
        stage,
        unit,
        argv,
        limit_secs: None,
    }
}

impl Manifest {
    /// # Errors
    /// What [`parse_versioned`] or [`TaskSpec::validate`] (against the task's own capabilities: the queue checked
    /// the grant at submit) or [`agent::argv`] (and for a session [`agent::session_argv`]) rejects, and a `rev` that
    /// would read as an option.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let m: Self = parse_versioned(json)?;
        m.task.validate(&m.task.capabilities)?;
        agent::argv(&m.task).map_err(|e| Error::Json(e.to_string()))?;
        if let Some(s) = &m.session {
            agent::session_argv(&m.task, &s.uuid, agent::Turn::Start, ("dtach", "env"))
                .and_then(|_| agent::turn_input(&m.task, &s.input, agent::Turn::Start))
                .map_err(|e| Error::Json(e.to_string()))?;
        }
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

    /// What the runner writes to the same marker to have the helper stop this attempt because the host powers off:
    /// a session's turn parks to continue elsewhere, a one-shot run goes back to the queue.
    #[must_use]
    pub fn drain_token(&self) -> String {
        format!("{} {} host_draining\n", self.attempt_id, self.lease_epoch)
    }

    /// The attempt's workspace under the guest user's home.
    ///
    /// # Errors
    /// What [`Workspace::new`] rejects.
    pub fn workspace(&self, guest_home: &str) -> Result<Workspace, workspace::Error> {
        Workspace::new(guest_home, &self.attempt_id, self.lease_epoch)
    }

    /// The guest commands in order: create the workspace, clone into it, check out the rev (an agent task on its
    /// [`agent::branch`]), then
    /// [`agent::argv`] in the task's workdir with the workspace's HOME. Each is an argv, never a shell string; `git`,
    /// `env` and `mkdir` are store paths the guest shares. Git reads the guest's system config alone, whose rewrite
    /// sends GitHub to the slot's proxy; the checkout's own config holds `identity` (name, email) for the agent's
    /// commits and, for a GitHub repository, an ssh push URL, which that rewrite sends to the proxy too.
    ///
    /// # Errors
    /// What [`agent::argv`] or [`Workspace::run`] rejects.
    pub fn steps(
        &self,
        ws: &Workspace,
        tools: (&str, &str, &str),
        identity: (&str, &str),
    ) -> Result<Vec<Step>, StepsError> {
        let (_, env, mkdir) = tools;
        let t = &self.task;
        let run = ws.run(env, &t.command.workdir, &agent::argv(t)?)?;
        let [root, dirs] = ws.create(mkdir);
        let [clone, checkout] = self.clone(&ws.checkout(), tools, identity)?;
        Ok(vec![
            step(Stage::Prepare, "exec-pool-root", root),
            step(Stage::Prepare, "exec-pool-workspace", dirs),
            step(Stage::Prepare, "exec-pool-clone", clone),
            step(Stage::Prepare, "exec-pool-checkout", checkout),
            step(Stage::Run, "exec-pool-task", run),
        ])
    }

    /// A session turn's preparing guest commands: the workspace's `tmp` and `out` in the slot home, on the turn that
    /// created the tree the clone into it and the checkout of the task's branch, then on every turn `relink`, which
    /// links the guest user's current Home Manager files into the session's HOME (they dangle after a deploy). The
    /// agent's own step follows the transcript probe: [`Manifest::turn`].
    ///
    /// # Errors
    /// What [`agent::branch`] rejects.
    pub fn session_steps(
        &self,
        ws: &Workspace,
        tools: (&str, &str, &str),
        identity: (&str, &str),
        (created, relink): (bool, Vec<String>),
    ) -> Result<Vec<Step>, StepsError> {
        let [root, dirs] = ws.create_scratch(tools.2);
        let mut steps = vec![
            step(Stage::Prepare, "exec-pool-root", root),
            step(Stage::Prepare, "exec-pool-workspace", dirs),
        ];
        if created {
            let [clone, checkout] = self.clone(SESSION_WORK, tools, identity)?;
            steps.push(step(Stage::Prepare, "exec-pool-clone", clone));
            steps.push(step(Stage::Prepare, "exec-pool-checkout", checkout));
        }
        steps.push(Step {
            limit_secs: Some(QUICK_SECS),
            ..step(Stage::Prepare, "exec-pool-relink", relink)
        });
        Ok(steps)
    }

    /// The session turn's agent step, in its tree: [`agent::session_argv`], `dtach` and `env` store paths; its input
    /// is prompted in the pane.
    ///
    /// # Errors
    /// [`agent::Error::NoSession`] for a one-shot manifest, what [`agent::session_argv`] or
    /// [`Workspace::run_session`] rejects.
    pub fn turn(
        &self,
        ws: &Workspace,
        (dtach, env): (&str, &str),
        turn: agent::Turn,
    ) -> Result<Step, StepsError> {
        let s = self
            .session
            .as_ref()
            .ok_or(agent::Error::NoSession(self.task.command.agent))?;
        let argv = agent::session_argv(&self.task, &s.uuid, turn, (dtach, env))?;
        Ok(step(
            Stage::Run,
            "exec-pool-task",
            ws.run_session(env, &self.task.command.workdir, &argv)?,
        ))
    }

    /// The clone into `checkout` and the checkout of the rev there, by `git` with no global config: the guest's
    /// system config alone, which sends GitHub to the slot's proxy (a private repository clones too).
    fn clone(
        &self,
        checkout: &str,
        (git, env, _): (&str, &str, &str),
        identity: (&str, &str),
    ) -> Result<[Vec<String>; 2], StepsError> {
        let s = |v: &[&str]| v.iter().map(|&x| x.to_owned()).collect::<Vec<_>>();
        let git = |args: &[&str]| {
            let mut v = s(&[env, "GIT_CONFIG_GLOBAL=/dev/null", git]);
            v.extend(s(args));
            v
        };
        let t = &self.task;
        // a none task is told nothing of a branch: its rev detached
        let on = match t.command.agent {
            Agent::None => vec!["--detach".to_owned()],
            _ => vec!["-b".to_owned(), agent::branch(t)?],
        };
        let mut checkout_args = s(&["-C", checkout, "checkout", "--quiet"]);
        checkout_args.extend(on);
        checkout_args.push(t.source.rev.clone());
        let checkout_args: Vec<&str> = checkout_args.iter().map(String::as_str).collect();
        let mut clone = s(&[
            "clone",
            "--quiet",
            "-c",
            &format!("user.name={}", identity.0),
            "-c",
            &format!("user.email={}", identity.1),
        ]);
        if let Some(url) = github_push_url(&t.source.repo) {
            clone.extend(["-c".to_owned(), format!("remote.origin.pushurl={url}")]);
        }
        clone.extend(s(&["--", &t.source.repo, checkout]));
        let clone: Vec<&str> = clone.iter().map(String::as_str).collect();
        Ok([git(&clone), git(&checkout_args)])
    }

    /// The guest command that lists the task's branch on its repository once the run is over, through the same config
    /// as the clone; [`pushed`] reads its output.
    ///
    /// # Errors
    /// What [`agent::branch`] rejects.
    pub fn pushed_check(&self, git: &str, env: &str) -> Result<Vec<String>, agent::Error> {
        let branch = agent::branch(&self.task)?;
        Ok([
            env,
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_TERMINAL_PROMPT=0",
            git,
            "ls-remote",
            "--heads",
            "--",
            &self.task.source.repo,
            &format!("refs/heads/{branch}"),
        ]
        .map(str::to_owned)
        .to_vec())
    }
}

/// The guest command whose output [`holds_tree`] reads: the checkout's HEAD and every change not committed.
///
/// Untracked files count; `git` reads no global or system config and writes no index refresh.
#[must_use]
pub fn tree_check(git: &str, env: &str, checkout: &str) -> Vec<String> {
    [
        env,
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_OPTIONAL_LOCKS=0",
        git,
        "-C",
        checkout,
        "status",
        "--porcelain=v2",
        "--branch",
        "--untracked-files=all",
    ]
    .map(str::to_owned)
    .to_vec()
}

/// Whether the task's branch as listed after the run (`after`) holds the whole tree.
///
/// That is: its commit is the checkout's HEAD and [`tree_check`]'s `status` (`None`: it failed) shows no change.
/// Anything else is unknown, so not.
#[must_use]
pub fn holds_tree(after: &Listed, status: Option<&str>) -> bool {
    let (Listed::At(pushed), Some(status)) = (after, status) else {
        return false;
    };
    let head = status.lines().find_map(|l| l.strip_prefix("# branch.oid "));
    head == Some(pushed.as_str()) && status.lines().all(|l| l.starts_with("# "))
}

/// The guest command that links the guest user's current Home Manager files into the session's HOME.
///
/// Every file of the generation under `guest_home` is linked, replacing what is there, and directories are made
/// writable ones, so the agent can write beside the links.
#[must_use]
pub fn relink(cp: &str, guest_home: &str) -> Vec<String> {
    [
        cp,
        // -H: the generation's home-files is itself a link to the files
        "-rsTH",
        "--no-preserve=mode",
        "--remove-destination",
        &format!("{guest_home}/.local/state/home-manager/gcroots/current-home/home-files"),
        SESSION_HOME,
    ]
    .map(str::to_owned)
    .to_vec()
}

/// The checkpoint a parked turn leaves: the session's tree as its turn at `epoch` left it.
///
/// It is on `host`, and in the store when it was `stored` there. A live tree has no content hash, so the generation
/// and the hosts say which it is.
#[must_use]
pub fn session_checkpoint(task_id: &str, host: &str, epoch: u64, stored: bool) -> CheckpointRef {
    let mut hosts = vec![host.to_owned()];
    if stored {
        hosts.push(STORE.to_owned());
    }
    CheckpointRef {
        schema_version: SchemaVersion::CURRENT,
        uri: format!("session-tree://{host}/{task_id}"),
        digest: "unhashed".to_owned(),
        generation: epoch,
        hosts,
    }
}

/// The failed steps of a session turn's pane in the runner's result: no Herdr, no turn to run, or a pane or prompt
/// that never reached the agent.
pub const PANE_STEPS: [&str; 3] = ["herdr", "turn", "prompt"];

/// Where a session turn goes: parked to wait for its next message, or settled as a one-shot run would be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnSettle {
    Park(ParkReason),
    Settle(Settle),
}

/// Where the session turn `attempt` at `epoch` goes after its run.
///
/// No result (or someone else's), a guest that went away, or a tree it could not find, is `needs_review`, its tree
/// left where it is; a cancel is `cancelled`; a turn that never reached the agent goes back to `queued`, except one
/// whose pane or prompt failed ([`PANE_STEPS`]), which parks as `turn_error`: retried, it fails the same way until the
/// session's attempts run out and it ends `failed` with its tree's uncommitted work. Every end of the agent's
/// call parks the session: `turn_timeout` for a call stopped at the time limit, `turn_end` for Claude's verdict of
/// success, `turn_error` otherwise. A failed turn never fails the session.
#[must_use]
pub fn decide_turn(
    attempt: &str,
    epoch: u64,
    result: Option<&ExecResult>,
    stdout: &str,
) -> TurnSettle {
    let Some(r) = result
        .filter(|r| r.attempt_id == attempt && r.lease_epoch == epoch && r.tree_lost.is_none())
    else {
        return TurnSettle::Settle(Settle::NeedsReview);
    };
    if r.cancelled {
        return TurnSettle::Settle(Settle::Cancelled);
    }
    if r.stage == Stage::Prepare {
        // before its agent ran, a drained turn's tree was neither changed nor pushed: it runs again where it may
        if r.drained {
            return TurnSettle::Settle(Settle::Drained);
        }
        if r.failed_step
            .as_deref()
            .is_some_and(|s| PANE_STEPS.contains(&s))
        {
            return TurnSettle::Park(ParkReason::TurnError);
        }
        return TurnSettle::Settle(Settle::Queued);
    }
    if !r.container_active {
        return TurnSettle::Settle(Settle::NeedsReview);
    }
    if r.drained {
        return TurnSettle::Park(ParkReason::HostDraining);
    }
    if r.timed_out {
        return TurnSettle::Park(ParkReason::TurnTimeout);
    }
    match agent::outcome(Agent::Claude, r.exit_code, stdout) {
        Outcome::Succeeded => TurnSettle::Park(ParkReason::TurnEnd),
        _ => TurnSettle::Park(ParkReason::TurnError),
    }
}

/// The ssh URL a push to an `https://github.com/<owner>/<repo>[.git]` repository goes to; `None` for any other.
#[must_use]
pub fn github_push_url(repo: &str) -> Option<String> {
    let path = repo.strip_prefix("https://github.com/")?;
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    let part = |p: &str| {
        !p.is_empty()
            && !p.starts_with(['-', '.'])
            && p.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
    };
    (part(owner) && part(name)).then(|| format!("git@github.com:{owner}/{name}.git"))
}

/// The commit `ls_remote`, the output of [`Manifest::pushed_check`], shows for `branch`; `None` when it shows none.
#[must_use]
pub fn remote_head(ls_remote: &str, branch: &str) -> Option<String> {
    let want = format!("refs/heads/{branch}");
    ls_remote
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .find(|(_, r)| *r == want)
        .map(|(sha, _)| sha.to_owned())
}

/// `branch` if this run handed code back on it.
///
/// That is: the repository shows it after the run (`after`) at another commit than before (`before`), so neither an
/// earlier run's branch nor one left as it was counts, and a listing that failed tells nothing.
#[must_use]
pub fn handed_back(before: &Listed, after: &Listed, branch: &str) -> Option<String> {
    match (before, after) {
        (Listed::Absent, Listed::At(_)) => Some(branch.to_owned()),
        (Listed::At(b), Listed::At(a)) if a != b => Some(branch.to_owned()),
        _ => None,
    }
}

/// What a listing of the task's branch showed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Listed {
    /// The listing failed.
    Unknown,
    Absent,
    /// The branch, at this commit.
    At(String),
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
#[expect(
    clippy::struct_excessive_bools,
    reason = "a record on the wire: each flag is one fact the helper reports, read on its own"
)]
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
    /// The helper stopped the attempt, before or during a step, for the runner's drain marker: the host powers off.
    #[serde(default)]
    pub drained: bool,
    /// The task's branch, `pool/<task id>`, when the repository shows it after the run.
    #[serde(default)]
    pub branch: Option<String>,
    /// Why a session task's tree, prepared on an earlier turn, could not be attached here (none to attach, or one
    /// this slot may not take): its session is not lost to a retry, it goes to review.
    #[serde(default)]
    pub tree_lost: Option<String>,
    /// Where a run that never reached its agent failed: a prepare step's unit, or `admit`, `attach`, `manifest`, `herdr`, `prompt` or
    /// `turn` outside one; `None` once its agent started, or for a run stopped by a cancel or a drain.
    #[serde(default)]
    pub failed_step: Option<String>,
    /// The turn's tree reached the store after its detach, at this turn's generation.
    #[serde(default)]
    pub stored: bool,
    /// [`holds_tree`] once the run's agent ran: the branch's head is the checkout's HEAD and nothing is uncommitted.
    #[serde(default)]
    pub handed_back: Option<bool>,
    /// What the session turn's agent asked with `pool-wait`, taken from its tree after the detach.
    #[serde(default)]
    pub wake: Option<Wake>,
    /// The last inbox message prompted into the session turn's pane while it ran ([`TurnHint::mail`]), which the
    /// park marks read with what the claim handed over.
    #[serde(default)]
    pub upto: Option<i64>,
    /// `container@<slot>` was active when the command ended; a guest that went away leaves the outcome unknown.
    pub container_active: bool,
    pub stdout_tail: String,
    pub stderr_tail: String,
    pub prepare_ms: u64,
    pub run_ms: u64,
}

impl ExecResult {
    /// The result of `m`'s run before its first step: in preparing, nothing exited yet.
    #[must_use]
    pub fn begun(m: &Manifest) -> Self {
        Self {
            schema_version: SchemaVersion::CURRENT,
            attempt_id: m.attempt_id.clone(),
            lease_epoch: m.lease_epoch,
            stage: Stage::Prepare,
            exit_code: None,
            timed_out: false,
            cancelled: false,
            branch: None,
            tree_lost: None,
            failed_step: None,
            stored: false,
            handed_back: None,
            wake: None,
            upto: None,
            drained: false,
            container_active: true,
            stdout_tail: String::new(),
            stderr_tail: String::new(),
            prepare_ms: 0,
            run_ms: 0,
        }
    }

    /// # Errors
    /// What [`parse_versioned`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        parse_versioned(json)
    }
}

/// What the runner tells the helper of a live session turn, on every heartbeat, beside the manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TurnHint {
    pub schema_version: SchemaVersion,
    /// How long an idle agent stays in its pane before its session parks: shorter while work waits for a slot.
    pub grace_secs: u64,
    /// The session's unread messages sent since its claim, by inbox id: the helper prompts each once.
    pub mail: Vec<(i64, String)>,
}

impl TurnHint {
    /// # Errors
    /// What [`parse_versioned`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        parse_versioned(json)
    }
}

/// Where the attempt `attempt` at `epoch` settles after its run.
///
/// A run the helper stopped for a cancel is `cancelled`, whatever stage it reached. One it stopped because the host
/// powers off is `drained` (run again elsewhere, its try given back) while it was preparing, and `interrupted` (to
/// review, as an ambiguous external mutation is never replayed) once its agent started. Otherwise only a run that never started the task's argv goes back to
/// `queued`. No result (or someone else's), a timeout or
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
    // drained before its agent started, a run starts again elsewhere, its try given back; after, what it did is
    // unknown, and it is not replayed
    if r.drained {
        return if r.stage == Stage::Prepare {
            Settle::Drained
        } else {
            Settle::Interrupted
        };
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
        Settle::NeedsReview | Settle::Interrupted => Outcome::NeedsReview,
        Settle::Waiting | Settle::Queued | Settle::Cancelled | Settle::Drained => return None,
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

/// Whether `hold_secs` from `now` (unix seconds) ends before the host's poweroff: for a claim, that its run starts
/// well ahead of the drain; for a running attempt, that the drain has not begun.
///
/// `show` is `systemctl show -p LoadState -p NextElapseUSecRealtime --timestamp=unix` of its off timer. A timer with no next elapse is stopped, as a switch restarting
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
    let next = field("NextElapseUSecRealtime")
        .ok_or_else(|| format!("off timer's next elapse missing: {show:?}"))?;
    next.strip_prefix('@')
        .and_then(|n| n.parse::<u64>().ok())
        .map(|off| now.saturating_add(u64::from(hold_secs)) <= off)
        .ok_or_else(|| format!("off timer's next elapse unread: {next:?}"))
}

/// The host's drain request, beside each slot's runtime directory: root writes it (`exec-pool-drain on`,
/// `modules/homelab/exec-pool-runner.nix`) with the unix second it holds until, and removes it.
pub const DRAIN_REQUEST: &str = "drain";

/// Whether a drain request reading `marker` still holds at `now` (unix seconds): until the second it names.
///
/// One that names none holds, so a torn write stops claims rather than lets a deploy cut a turn; the deadline bounds a
/// request whose deploy died before it cleared it.
#[must_use]
pub fn drain_holds(marker: &str, now: u64) -> bool {
    marker
        .trim()
        .parse::<u64>()
        .ok()
        .is_none_or(|until| now < until)
}

/// `f`, again every `wait` while the queue is [`QueueError::Unavailable`] and `patience` lasts.
///
/// Nothing was committed then, so a retry cannot land twice, and a turn that ends while the queue restarts still
/// settles or parks. Any other outcome, [`QueueError::OutcomeUnknown`] included, is returned as it is.
///
/// # Errors
/// What `f` last returned.
pub fn while_unavailable<T>(
    patience: Duration,
    wait: Duration,
    mut f: impl FnMut() -> Result<T, QueueError>,
) -> Result<T, QueueError> {
    let t = Instant::now();
    loop {
        match f() {
            Err(QueueError::Unavailable(_)) if t.elapsed().saturating_add(wait) < patience => {
                thread::sleep(wait);
            }
            r => return r,
        }
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
    read_regular_up_to(path, READ_LIMIT)
}

/// [`read_regular`] with its own bound of `limit` bytes.
///
/// # Errors
/// As [`read_regular`].
pub fn read_regular_up_to(path: &Path, limit: u64) -> io::Result<String> {
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
    file.take(limit.saturating_add(1)).read_to_string(&mut s)?;
    if u64::try_from(s.len()).map_or(true, |n| n > limit) {
        return Err(io::Error::other(format!(
            "{} is over {limit} bytes",
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
    fn a_drain_request_holds_until_its_deadline_and_a_torn_one_holds() {
        assert!(drain_holds("1000\n", 999));
        assert!(!drain_holds("1000\n", 1000));
        assert!(drain_holds("", 5));
        assert!(drain_holds("soon", 5));
    }

    #[test]
    fn the_queue_away_is_waited_out_and_nothing_else_is_retried() {
        let mut calls = 0_u32;
        let r = while_unavailable(Duration::from_secs(5), Duration::from_millis(1), || {
            calls = calls.saturating_add(1);
            if calls < 3 {
                Err(QueueError::Unavailable("restarting".to_owned()))
            } else {
                Ok(calls)
            }
        });
        assert!(matches!(r, Ok(3)));
        let mut calls = 0_u32;
        let r: Result<(), _> =
            while_unavailable(Duration::from_secs(5), Duration::from_millis(1), || {
                calls = calls.saturating_add(1);
                Err(QueueError::OutcomeUnknown("commit".to_owned()))
            });
        assert!(matches!(r, Err(QueueError::OutcomeUnknown(_))) && calls == 1);
        // past its patience the outage is the caller's: the lease is the reconciler's to expire
        let r: Result<(), _> = while_unavailable(Duration::ZERO, Duration::from_millis(1), || {
            Err(QueueError::Unavailable("down".to_owned()))
        });
        assert!(matches!(r, Err(QueueError::Unavailable(_))));
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
            branch: None,
            tree_lost: None,
            failed_step: None,
            stored: false,
            handed_back: None,
            wake: None,
            upto: None,
            drained: false,
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
        let all: Vec<(Stage, Vec<String>)> = m
            .steps(
                &ws,
                ("/git", "/env", "/mkdir"),
                ("Pool", "pool@example.org"),
            )
            .unwrap()
            .into_iter()
            .map(|s| (s.stage, s.argv))
            .collect();
        all.try_into().unwrap()
    }

    const UUID: &str = "a3a7c578-9125-8a32-a933-73a095d4a27b";

    fn session(input: &str) -> Manifest {
        let mut t = task();
        t["command"] =
            json!({ "agent": "claude", "argv": ["fix it", "opus"], "workdir": "crates/x" });
        Manifest::parse(
            &json!({ "schema_version": 1, "slot": "pool1", "attempt_id": "t1.a", "lease_epoch": 3, "task": t,
                     "session": { "uuid": UUID, "input": input, "upto": 7 } })
            .to_string(),
        )
        .unwrap()
    }

    fn session_steps(m: &Manifest, created: bool) -> Vec<Step> {
        let ws = m.workspace("/home/u").unwrap();
        m.session_steps(
            &ws,
            ("/git", "/env", "/mkdir"),
            ("Pool", "pool@example.org"),
            (created, relink("/cp", "/home/u")),
        )
        .unwrap()
    }

    #[test]
    fn a_first_turn_clones_into_its_tree_and_a_later_one_only_relinks() {
        let m = session("fix it");
        let units = |steps: &[Step]| steps.iter().map(|s| s.unit).collect::<Vec<_>>();
        let first = session_steps(&m, true);
        assert_eq!(
            units(&first),
            [
                "exec-pool-root",
                "exec-pool-workspace",
                "exec-pool-clone",
                "exec-pool-checkout",
                "exec-pool-relink"
            ]
        );
        assert!(first.iter().all(|s| s.stage == Stage::Prepare));
        // the scratch in the slot home, the checkout in the tree, on the task's branch
        let dir = "/home/u/attempts/74312e61-3";
        assert_eq!(
            first[1].argv,
            [
                "/mkdir",
                "-m",
                "0700",
                "--",
                dir,
                &format!("{dir}/tmp"),
                &format!("{dir}/out")
            ]
        );
        assert!(first[2].argv.ends_with(&[
            "--".into(),
            "https://example.org/r.git".into(),
            SESSION_WORK.into()
        ]));
        assert!(
            first[3]
                .argv
                .ends_with(&["-b".into(), "pool/t1".into(), "abc123".into()])
        );
        assert_eq!(
            first[4].argv,
            [
                "/cp",
                "-rsTH",
                "--no-preserve=mode",
                "--remove-destination",
                "/home/u/.local/state/home-manager/gcroots/current-home/home-files",
                SESSION_HOME
            ]
        );
        let later = session_steps(&m, false);
        assert_eq!(
            units(&later),
            ["exec-pool-root", "exec-pool-workspace", "exec-pool-relink"]
        );
    }

    #[test]
    fn a_turn_starts_its_session_until_a_transcript_exists_then_resumes_it() {
        let m = session("now add a test");
        let ws = m.workspace("/home/u").unwrap();
        let tools = ("/dtach", "/env");
        let start = m.turn(&ws, tools, agent::Turn::Start).unwrap();
        assert_eq!(start.stage, Stage::Run);
        assert_eq!(
            start.argv[..6],
            [
                "/env",
                "-C",
                &format!("{SESSION_WORK}/crates/x"),
                "--",
                &format!("HOME={SESSION_HOME}"),
                "TMPDIR=/home/u/attempts/74312e61-3/tmp"
            ]
        );
        // interactive Claude as a named worker ran it, in a terminal the slot's pane attaches to: no print mode
        assert_eq!(
            start.argv[6..],
            [
                "/dtach",
                "-N",
                agent::AGENT_SOCKET,
                "/env",
                "TERM=xterm-256color",
                "HERDR_AUTOATTACH_DISABLED=1",
                "fish",
                "-c",
                "claude $argv",
                "--",
                "--dangerously-skip-permissions",
                "--model",
                "opus",
                "--session-id",
                UUID
            ]
        );
        let resumed = m.turn(&ws, tools, agent::Turn::Resume).unwrap();
        assert_eq!(resumed.argv[resumed.argv.len() - 2..], ["--resume", UUID]);
        assert!(
            !start
                .argv
                .iter()
                .any(|a| a == "-p" || a.contains("now add a test"))
        );
        let one_shot = manifest(&task()).unwrap();
        assert!(one_shot.turn(&ws, tools, agent::Turn::Start).is_err());
    }

    #[test]
    fn a_turn_is_told_the_rules_when_it_starts_its_session_and_only_its_input_after() {
        let m = session("now add a test");
        let start = agent::turn_input(&m.task, "now add a test", agent::Turn::Start).unwrap();
        assert!(
            start.starts_with("You run as an execution pool task")
                && start.contains("pool-wait")
                && start.ends_with("now add a test")
        );
        assert_eq!(
            agent::turn_input(&m.task, "now add a test", agent::Turn::Resume).unwrap(),
            "now add a test"
        );
        assert!(agent::turn_input(&m.task, "", agent::Turn::Resume).is_err());
    }

    #[test]
    fn a_parked_turn_names_its_tree_on_this_host() {
        let c = session_checkpoint("t1", "msi-ms7758", 4, false);
        assert_eq!(c.validate(), Ok(()), "what Store::park validates");
        assert_eq!(
            (c.uri.as_str(), c.generation, c.hosts.as_slice()),
            (
                "session-tree://msi-ms7758/t1",
                4,
                &["msi-ms7758".to_owned()][..]
            )
        );
        let stored = session_checkpoint("t1", "msi-ms7758", 4, true);
        assert_eq!(stored.hosts, ["msi-ms7758", STORE]);
    }

    #[test]
    fn a_run_stopped_for_a_poweroff_parks_its_turn_or_goes_back_to_the_queue() {
        let drained = ExecResult {
            drained: true,
            exit_code: None,
            ..result(Stage::Run, Some(0))
        };
        assert_eq!(
            decide_turn("t1.a", 3, Some(&drained), ""),
            TurnSettle::Park(ParkReason::HostDraining)
        );
        assert_eq!(
            decide("t1.a", 3, Agent::Claude, Some(&drained), ""),
            Settle::Interrupted,
            "a one-shot run its agent began may have pushed: review, never a replay"
        );
        assert!(receipt("t1", "t1.a", 3, Settle::Interrupted).is_some());
        let preparing = ExecResult {
            stage: Stage::Prepare,
            ..drained
        };
        assert_eq!(
            decide("t1.a", 3, Agent::Claude, Some(&preparing), ""),
            Settle::Drained,
            "one its agent never reached starts again elsewhere"
        );
        assert_eq!(
            decide_turn("t1.a", 3, Some(&preparing), ""),
            TurnSettle::Settle(Settle::Drained),
            "a turn its agent never reached runs again, its tree as it was"
        );
        let m = manifest(&task()).unwrap();
        assert_ne!(m.drain_token(), m.cancel_token());
        assert!(m.drain_token().starts_with(m.cancel_token().trim_end()));
    }

    #[test]
    fn every_end_of_a_turn_parks_the_session_and_an_unknown_one_goes_to_review() {
        let turn = |r: Option<&ExecResult>, stdout: &str| decide_turn("t1.a", 3, r, stdout);
        let ok = result(Stage::Run, Some(0));
        assert_eq!(
            turn(Some(&ok), "{\"is_error\":false}"),
            TurnSettle::Park(ParkReason::TurnEnd)
        );
        for (r, stdout) in [
            (result(Stage::Run, Some(0)), "{\"is_error\":true}"),
            (result(Stage::Run, Some(1)), ""),
            (result(Stage::Run, None), ""),
        ] {
            assert_eq!(
                turn(Some(&r), stdout),
                TurnSettle::Park(ParkReason::TurnError),
                "{r:?}"
            );
        }
        let timed_out = ExecResult {
            timed_out: true,
            ..result(Stage::Run, Some(143))
        };
        assert_eq!(
            turn(Some(&timed_out), "{\"is_error\":false}"),
            TurnSettle::Park(ParkReason::TurnTimeout)
        );
        assert_eq!(turn(None, ""), TurnSettle::Settle(Settle::NeedsReview));
        let lost = ExecResult {
            tree_lost: Some("no session tree at /x".to_owned()),
            ..result(Stage::Prepare, None)
        };
        assert_eq!(
            turn(Some(&lost), ""),
            TurnSettle::Settle(Settle::NeedsReview),
            "a prepared tree it could not find is not retried away"
        );
        assert_eq!(
            decide_turn("t1.a", 2, Some(&ok), ""),
            TurnSettle::Settle(Settle::NeedsReview),
            "another epoch's result"
        );
        let gone = ExecResult {
            container_active: false,
            ..ok.clone()
        };
        assert_eq!(
            turn(Some(&gone), ""),
            TurnSettle::Settle(Settle::NeedsReview)
        );
        assert_eq!(
            turn(Some(&result(Stage::Prepare, Some(1))), ""),
            TurnSettle::Settle(Settle::Queued)
        );
        for step in PANE_STEPS {
            let failed = ExecResult {
                failed_step: Some(step.to_owned()),
                ..result(Stage::Prepare, Some(1))
            };
            assert_eq!(
                turn(Some(&failed), ""),
                TurnSettle::Park(ParkReason::TurnError),
                "a failed {step} step parks the session, never spends its attempts"
            );
        }
        let cancelled = ExecResult {
            cancelled: true,
            ..ok
        };
        assert_eq!(
            turn(Some(&cancelled), ""),
            TurnSettle::Settle(Settle::Cancelled)
        );
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
        let git = ["/env", "GIT_CONFIG_GLOBAL=/dev/null", "/git"];
        assert_eq!(clone[..3], git, "no rewrite to ssh from the user's config");
        assert_eq!(checkout[..3], git);
        assert_eq!(
            clone[3..],
            [
                "clone",
                "--quiet",
                "-c",
                "user.name=Pool",
                "-c",
                "user.email=pool@example.org",
                "--",
                "https://example.org/r.git",
                &format!("{dir}/work")
            ]
        );
        assert_eq!(
            checkout[3..],
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
    fn a_github_checkout_pushes_over_ssh_and_its_branch_is_read_back() {
        let mut t = task();
        t["source"]["repo"] = json!("https://github.com/sammasak/nixos-config.git");
        t["command"] = json!({ "agent": "claude", "argv": ["go"], "workdir": "." });
        let m = manifest(&t).unwrap();
        let [_, _, (_, clone), (_, checkout), _] = steps(&m);
        assert_eq!(checkout[7..], ["-b", "pool/t1", "abc123"]);
        let at = clone.iter().position(|a| a == "--").unwrap();
        assert_eq!(
            clone[at - 2..at],
            [
                "-c",
                "remote.origin.pushurl=git@github.com:sammasak/nixos-config.git"
            ]
        );
        for (repo, want) in [
            ("https://github.com/o/r", Some("git@github.com:o/r.git")),
            (
                "https://github.com/o/r.x.git",
                Some("git@github.com:o/r.x.git"),
            ),
            ("https://github.com/o/r/extra", None),
            ("https://github.com/-o/r", None),
            ("https://github.com/o/", None),
            ("https://gitlab.com/o/r", None),
            ("http://github.com/o/r", None),
        ] {
            assert_eq!(github_push_url(repo).as_deref(), want, "{repo}");
        }
        assert_eq!(
            m.pushed_check("/git", "/env").unwrap()[4..],
            [
                "ls-remote",
                "--heads",
                "--",
                "https://github.com/sammasak/nixos-config.git",
                "refs/heads/pool/t1"
            ]
        );
        let shown = "1f2e\trefs/heads/pool/t1\n";
        assert_eq!(remote_head(shown, "pool/t1").as_deref(), Some("1f2e"));
        assert_eq!(remote_head("1f2e\trefs/heads/pool/t10\n", "pool/t1"), None);
        assert_eq!(remote_head("", "pool/t1"), None);
        let at = |sha: &str| Listed::At(sha.to_owned());
        let b = "pool/t1";
        let (absent, unknown) = (Listed::Absent, Listed::Unknown);
        assert_eq!(
            handed_back(&absent, &at("1f2e"), b).as_deref(),
            Some(b),
            "new"
        );
        assert_eq!(
            handed_back(&at("0a0a"), &at("1f2e"), b).as_deref(),
            Some(b),
            "moved"
        );
        assert_eq!(
            handed_back(&at("1f2e"), &at("1f2e"), b),
            None,
            "an earlier run's, as it was"
        );
        assert_eq!(handed_back(&absent, &absent, b), None, "none pushed");
        assert_eq!(
            handed_back(&unknown, &at("1f2e"), b),
            None,
            "unknown before"
        );
        assert_eq!(handed_back(&absent, &unknown, b), None, "unknown after");
    }

    #[test]
    fn the_tree_is_handed_back_only_when_its_head_is_pushed_and_nothing_is_uncommitted() {
        assert_eq!(
            tree_check("/git", "/env", "/session/cur/work")[4..8],
            ["/git", "-C", "/session/cur/work", "status"]
        );
        let at = |sha: &str| Listed::At(sha.to_owned());
        let clean = "# branch.oid 1f2e\n# branch.head pool/t1\n";
        assert!(holds_tree(&at("1f2e"), Some(clean)));
        for (after, status, why) in [
            (at("0a0a"), Some(clean), "HEAD is not the pushed commit"),
            (
                at("1f2e"),
                Some("# branch.oid 1f2e\n1 .M N... 100644 100644 100644 a b src/lib.rs\n"),
                "a change not committed",
            ),
            (
                at("1f2e"),
                Some("# branch.oid 1f2e\n? notes.md\n"),
                "an untracked file",
            ),
            (at("1f2e"), None, "the status failed"),
            (Listed::Absent, Some(clean), "nothing pushed"),
            (Listed::Unknown, Some(clean), "the listing failed"),
            (at("1f2e"), Some(""), "no HEAD"),
        ] {
            assert!(!holds_tree(&after, status), "{why}");
        }
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
