//! The durable queue (#651): tasks and attempts in PostgreSQL, reached over a Unix socket only.
//!
//! Every change goes through [`transition`] and then through the database's own fence (`attempts_fence` in the migration), in one
//! transaction that also appends the event; a claim takes rows with `FOR UPDATE SKIP LOCKED`, so two claimers never
//! get the same attempt.

use std::fmt::Write as _;
use std::str::FromStr;

use postgres::config::Host;
use postgres::error::SqlState;
use postgres::{Client, Config, GenericClient, NoTls, Row, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::task_result::TaskResult;
use crate::wake::Wake;
use crate::{
    Attempt, CheckpointRef, Error, Event, Kind, ParkReason, Placement, Receipt, Resolution,
    RetryPolicy, SchemaVersion, Settle, Slot, Status, TaskSpec, transition,
};

pub const UP: &str = include_str!("../migrations/0001_queue.up.sql");
pub const DOWN: &str = include_str!("../migrations/0001_queue.down.sql");
/// Each migration, ascending, by the version it records; `migrate` applies every one the database has not recorded.
/// From 7 each records its floor, the oldest VERSION whose reads and writes stay correct on it: an additive one keeps
/// the previous floor, so a binary rolled back across it still serves; one an older binary would misread or break by
/// its writes records its own version.
const STEPS: [(i32, &str); 18] = [
    (1, UP),
    (2, include_str!("../migrations/0002_submitter.up.sql")),
    (3, include_str!("../migrations/0003_result.up.sql")),
    (4, include_str!("../migrations/0004_runner.up.sql")),
    (5, include_str!("../migrations/0005_cancel.up.sql")),
    (6, include_str!("../migrations/0006_branch.up.sql")),
    (7, include_str!("../migrations/0007_quarantine.up.sql")),
    (8, include_str!("../migrations/0008_slots.up.sql")),
    (9, include_str!("../migrations/0009_session.up.sql")),
    (
        10,
        include_str!("../migrations/0010_session_metrics.up.sql"),
    ),
    (11, include_str!("../migrations/0011_claim_host.up.sql")),
    (
        12,
        include_str!("../migrations/0012_session_gc_handed_back.up.sql"),
    ),
    (13, include_str!("../migrations/0013_drain_reason.up.sql")),
    (14, include_str!("../migrations/0014_timer.up.sql")),
    (15, include_str!("../migrations/0015_turn_log.up.sql")),
    (16, include_str!("../migrations/0016_priority.up.sql")),
    (17, include_str!("../migrations/0017_transcript.up.sql")),
    (18, include_str!("../migrations/0018_undelivered.up.sql")),
];
const DOWN_SUBMITTER: &str = include_str!("../migrations/0002_submitter.down.sql");
const DOWN_RESULT: &str = include_str!("../migrations/0003_result.down.sql");
const DOWN_CANCEL: &str = include_str!("../migrations/0005_cancel.down.sql");
const DOWN_QUARANTINE: &str = include_str!("../migrations/0007_quarantine.down.sql");
const DOWN_SLOTS: &str = include_str!("../migrations/0008_slots.down.sql");
const DOWN_SESSION: &str = include_str!("../migrations/0009_session.down.sql");
const DOWN_SESSION_METRICS: &str = include_str!("../migrations/0010_session_metrics.down.sql");
const DOWN_CLAIM_HOST: &str = include_str!("../migrations/0011_claim_host.down.sql");
const DOWN_DRAIN_REASON: &str = include_str!("../migrations/0013_drain_reason.down.sql");
const DOWN_TIMER: &str = include_str!("../migrations/0014_timer.down.sql");
const DOWN_TURN_LOG: &str = include_str!("../migrations/0015_turn_log.down.sql");
const DOWN_PRIORITY: &str = include_str!("../migrations/0016_priority.down.sql");
const DOWN_TRANSCRIPT: &str = include_str!("../migrations/0017_transcript.down.sql");
const DOWN_UNDELIVERED: &str = include_str!("../migrations/0018_undelivered.down.sql");
const VERSION: i32 = 18;
/// The fence's SQLSTATE, raised by `attempts_fence`.
const FENCED: &str = "XP409";
const LIVE: &str = "('leased', 'running', 'checkpointing')";
/// The HELP and TYPE lines both renderings of `exec_pool_queue_up` start with.
macro_rules! up_help {
    () => {
        "# HELP exec_pool_queue_up Whether the queue database answered; without it the series below are absent.\n\
         # TYPE exec_pool_queue_up gauge\n"
    };
}

/// The whole rendering while the database is unreachable: absent, not zero.
pub const METRICS_UNAVAILABLE: &str = concat!(up_help!(), "exec_pool_queue_up 0\n");

/// The agent kinds a task's `command.agent` may name, as serialized.
const AGENTS: [&str; 4] = ["none", "claude", "codex", "pi"];

const STATUSES: [Status; 9] = [
    Status::Queued,
    Status::Leased,
    Status::Running,
    Status::Checkpointing,
    Status::Waiting,
    Status::Succeeded,
    Status::Failed,
    Status::NeedsReview,
    Status::Cancelled,
];

#[derive(Debug, thiserror::Error)]
pub enum QueueError {
    #[error(transparent)]
    Contract(#[from] Error),
    /// The database did not answer, or is starting, stopping or full; nothing was changed. Safe to retry.
    #[error("queue database unavailable: {0}")]
    Unavailable(String),
    /// The connection went away during COMMIT: the change may or may not have landed. Read the attempt's state
    /// before doing anything else; never replay blindly.
    #[error("outcome unknown, the connection was lost while committing: {0}")]
    OutcomeUnknown(String),
    /// A value the client could not encode or decode: a bug or a schema mismatch, not an outage.
    #[error("queue client error: {0}")]
    Client(String),
    #[error("the database refused a stale write: {0}")]
    Fenced(String),
    #[error("database error {code}: {message}")]
    Db { code: String, message: String },
    #[error("the queue connects over a Unix socket only; give host=/path/to/socket/dir")]
    NotUnixSocket,
    /// A remote runner's conninfo: TCP hosts alone, and no password of its own (it comes from the credential).
    #[error("a remote queue is TCP hosts with no password in the conninfo")]
    NotRemote,
    #[error(
        "the database is at migration {0}, which needs a binary newer than this one's {VERSION}"
    )]
    SchemaAhead(i32),
    #[error("the database is not migrated")]
    NotMigrated,
    #[error("no attempt {0}")]
    NotFound(String),
    #[error("attempt {0} holds no live lease")]
    NotLive(String),
    /// A park of a one-shot task's attempt, which has no inbox to wake it.
    #[error("attempt {0} is not a session's")]
    NotSession(String),
    /// The event, a settle to the named state, came without a receipt it needs or with one it may not carry.
    #[error(
        "a receipt goes with a settle to succeeded, failed or needs_review, and only there (this one: {0:?})"
    )]
    Receipt(Status),
    #[error("{0} is out of range")]
    Range(&'static str),
}

/// Connection exceptions, a server shutting down or starting up, and too many connections.
fn unavailable(code: &str) -> bool {
    code.starts_with("08") || matches!(code, "57P01" | "57P02" | "57P03" | "53300")
}

impl From<postgres::Error> for QueueError {
    fn from(e: postgres::Error) -> Self {
        match e.as_db_error() {
            Some(db) if db.code() == &SqlState::from_code(FENCED) => {
                Self::Fenced(db.message().to_owned())
            }
            // a FATAL or PANIC ends the session whatever its code, but a refused login or a missing database is
            // a misconfiguration, not an outage to wait out
            Some(db)
                if unavailable(db.code().code())
                    || (matches!(db.severity(), "FATAL" | "PANIC")
                        && !db.code().code().starts_with("28")
                        && db.code().code() != "3D000") =>
            {
                Self::Unavailable(db.message().to_owned())
            }
            Some(db) => Self::Db {
                code: db.code().code().to_owned(),
                message: db.message().to_owned(),
            },
            None if e.is_closed()
                || std::error::Error::source(&e)
                    .is_some_and(<dyn std::error::Error>::is::<std::io::Error>) =>
            {
                Self::Unavailable(e.to_string())
            }
            None => Self::Client(e.to_string()),
        }
    }
}

impl From<serde_json::Error> for QueueError {
    fn from(e: serde_json::Error) -> Self {
        Self::Contract(e.into())
    }
}

/// How long an attempt has been in the state it left, and since its task was submitted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Durations {
    pub in_state_ms: i64,
    pub since_submit_ms: i64,
}

/// One state change, as appended to `events` and logged as one JSON line. Ids belong here, never in a metric label.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Change {
    pub task_id: String,
    pub attempt: String,
    pub lease_epoch: u64,
    pub host: Option<String>,
    pub slot: Option<String>,
    pub from: Option<Status>,
    pub to: Status,
    pub reason: &'static str,
    pub durations: Durations,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Submitted {
    New {
        attempt: String,
        change: Change,
    },
    /// The same task under its key, already queued: at-least-once delivery.
    Duplicate {
        attempt: String,
    },
}

#[derive(Debug)]
pub struct Claim {
    pub task: TaskSpec,
    pub attempt: Attempt,
    pub change: Change,
    /// What a session's turn runs on; `None` for a one-shot task.
    pub turn: Option<Turn>,
}

/// One turn of a session, as its claim hands it over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Turn {
    pub session_uuid: String,
    /// The task's prompt on the first turn; after it, the unread inbox rows, a `continue` first, then oldest first,
    /// each a paragraph.
    pub input: String,
    /// The highest inbox id in `input`, 0 for none: the rows the turn's [`Park`] marks read. A turn that never parks
    /// marks none, so the next is handed them again.
    pub upto: i64,
    /// No turn of the session has started before this one: the agent's session does not exist yet.
    pub first: bool,
    /// Where the last park left the session's tree; `None` before its first park.
    pub checkpoint: Option<CheckpointRef>,
    /// The agent's transcript as the last park that had one left it; `None` on the first turn.
    pub transcript: Option<Transcript>,
}

/// The largest transcript the queue keeps for a session, as `transcripts.body` bounds it.
pub const TRANSCRIPT_BYTES: usize = 32 << 20;

/// A session's agent transcript: what `--resume` reads, kept in the queue alone (it holds tool output).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transcript {
    /// The directory under `~/.claude/projects` it was found in, one path component.
    pub project: String,
    pub body: Vec<u8>,
}

impl Transcript {
    /// Whether `project` names one directory, as the queue's check does.
    #[must_use]
    pub fn valid_project(project: &str) -> bool {
        (1..=255).contains(&project.len())
            && !matches!(project, "." | "..")
            && project
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    }
}

/// How a session's turn ends, for [`Store::park`].
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Park {
    pub reason: ParkReason,
    /// Recorded on the attempt with `generation` set to the turn's epoch; `None` keeps the one it has.
    pub checkpoint: Option<CheckpointRef>,
    /// The turn's result, recorded with the park so a re-lease cannot fence it out.
    pub result: TaskResult,
    /// [`Turn::upto`] of the claim the turn ran.
    pub upto: i64,
    /// The turn's input never reached the agent (`runner::parks_undelivered`): nothing is marked read, and the next
    /// turn is handed it again.
    #[serde(default)]
    pub undelivered: bool,
    /// The time the turn asked to be woken at (`pool-wait`), put in the inbox as a timer row.
    #[serde(default)]
    pub wake: Option<Wake>,
    /// The agent's transcript after the turn, replacing the session's; `None` keeps the one it has.
    #[serde(skip)]
    pub transcript: Option<Transcript>,
}

/// What a `continue` row reads as in a turn's input: a turn stopped before it ended.
const CONTINUE: &str =
    "Your previous turn was stopped before it ended. Continue where you left off.";
/// A timer row's text when it carries no note.
const TIMER: &str = "The time you asked to be woken at has come.";
/// A `continue` row's text after a park for a host draining, for a poweroff or a deploy: the turn was stopped mid-action.
const DRAINED: &str = "You were paused mid-turn by the pool (its host was powering off or being deployed). Check \
    the state of your last action before continuing.";

/// A `continue` row's text after a park for a turn stopped at its time limit.
const TIMED_OUT: &str = "Your last turn hit the time limit. Check your last action, then continue.";
/// Turns in a row that end in a timeout, no message in between, after which a session waits instead of continuing.
pub const TIMEOUTS_IN_A_ROW: usize = 3;

/// How many of `attempt`'s last turns, the one just parked included, ended in a timeout with no message read since the
/// first of them; a turn that read a message is the first of a run.
fn timeouts_in_a_row(
    tx: &mut Transaction<'_>,
    task: &str,
    attempt: &str,
) -> Result<usize, QueueError> {
    let mut n: usize = 0;
    for r in tx.query(
        &format!(
            "SELECT e.reason, EXISTS (SELECT FROM inbox i WHERE i.task_id = $1 AND i.kind = 'message' \
             AND i.consumed_epoch = e.lease_epoch) FROM events e WHERE e.attempt_id = $2 \
             AND e.to_status = 'waiting' ORDER BY e.id DESC LIMIT {TIMEOUTS_IN_A_ROW}"
        ),
        &[&task, &attempt],
    )? {
        let (reason, told): (&str, bool) = (r.try_get(0)?, r.try_get(1)?);
        if reason != ParkReason::TurnTimeout.as_str() {
            break;
        }
        n = n.saturating_add(1);
        if told {
            break;
        }
    }
    Ok(n)
}

/// What [`Store::logs`] found of a task's output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Logs {
    /// The attempt is queued or live: a turn may still log, or log more.
    pub pending: bool,
    pub turn: Option<TurnLog>,
}

/// One turn's log as the runner last put it: its tail from byte `start` of the whole output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnLog {
    pub turn: u64,
    pub turns: u64,
    pub lease_epoch: u64,
    pub start: u64,
    pub log: Vec<u8>,
    /// The turn still runs: its runner rewrites the log at every heartbeat.
    pub live: bool,
}

/// A connection that reconnects on the next call after the database went away.
pub struct Store {
    config: Config,
    client: Option<Client>,
}

const fn status_str(s: Status) -> &'static str {
    match s {
        Status::Queued => "queued",
        Status::Leased => "leased",
        Status::Running => "running",
        Status::Checkpointing => "checkpointing",
        Status::Waiting => "waiting",
        Status::Succeeded => "succeeded",
        Status::Failed => "failed",
        Status::NeedsReview => "needs_review",
        Status::Cancelled => "cancelled",
    }
}

fn parse_status(s: &str) -> Result<Status, QueueError> {
    Ok(serde_json::from_value(Value::String(s.to_owned()))?)
}

fn i64_of(field: &'static str, v: u64) -> Result<i64, QueueError> {
    i64::try_from(v).map_err(|_| QueueError::Range(field))
}

fn u64_of(field: &'static str, v: i64) -> Result<u64, QueueError> {
    u64::try_from(v).map_err(|_| QueueError::Range(field))
}

/// Why an event moved the attempt to `to`: a bounded code, safe as a metric label.
const fn reason(kind: &Kind, to: Status) -> &'static str {
    match (kind, to) {
        (Kind::Settle(Settle::Failed) | Kind::Resolve(Resolution::Failed), _) => "failed",
        (Kind::Settle(Settle::Drained), Status::Queued)
        | (Kind::Settle(Settle::Interrupted), Status::NeedsReview) => "host_draining",
        (_, Status::Cancelled) => "cancelled",
        (_, Status::Failed) => "attempts_exhausted",
        (Kind::Lease(_), _) => "lease",
        (Kind::Start, _) => "start",
        (Kind::Checkpoint, _) => "checkpoint",
        (Kind::Settle(_), _) => "settle",
        (Kind::Park(why), _) => why.as_str(),
        (Kind::Wake, _) => "wake",
        (Kind::Expire, _) => "lease_expired",
        (Kind::Resolve(_), _) => "operator",
    }
}

/// For a session task, the host its attempt last ran on (`running`), under `a` and `t`; null for a one-shot task.
/// The order a claim takes queued attempts in: the task's priority, higher first, plus one for every 10 minutes the
/// attempt has waited queued, so a low priority is not starved; then the oldest.
const CLAIM_ORDER: &str =
    "t.priority + floor(extract(epoch FROM now() - a.changed_at) / 600) DESC, a.changed_at, a.id";

/// The columns an attempt row is read with, under `a` (attempts) and `t` (tasks).
const ATTEMPT_COLS: &str = "a.id, a.task_id, a.lease_epoch, a.tries, a.status, a.host, a.slot, a.pins, \
    a.cancel_requested, t.max_attempts, (a.lease_deadline <= clock_timestamp()) AS expired, \
    (extract(epoch FROM now() - a.changed_at) * 1000)::bigint AS in_state_ms, \
    (extract(epoch FROM now() - t.submitted_at) * 1000)::bigint AS since_submit_ms";

/// One task and its attempt as `status` and `list` show them, under `a` (attempts) and `t` (`task_summaries`).
const SUMMARY: &str = "jsonb_build_object('task', t.id, 'attempt', a.id, 'status', a.status, \
    'agent', t.agent, 'repo', t.repo, 'rev', t.rev, 'session', t.session, \
    'parked', CASE WHEN a.status = 'waiting' THEN (SELECT e.reason FROM events e \
    WHERE e.attempt_id = a.id AND e.to_status = 'waiting' ORDER BY e.id DESC LIMIT 1) END, \
    'workdir', t.workdir, 'lease_epoch', a.lease_epoch, 'tries', a.tries, 'host', a.host, \
    'slot', a.slot, 'submitted_at', t.submitted_at, 'changed_at', a.changed_at)";

struct Locked {
    attempt: Attempt,
    cancel_requested: bool,
    retry: RetryPolicy,
    expired: bool,
    durations: Durations,
}

fn locked(row: &Row) -> Result<Locked, QueueError> {
    let host: Option<String> = row.try_get("host")?;
    let slot: Option<String> = row.try_get("slot")?;
    let max_attempts: i32 = row.try_get("max_attempts")?;
    let tries: i32 = row.try_get("tries")?;
    let attempt = Attempt {
        schema_version: SchemaVersion::CURRENT,
        id: row.try_get("id")?,
        task_id: row.try_get("task_id")?,
        lease_epoch: u64_of("lease_epoch", row.try_get("lease_epoch")?)?,
        tries: u32::try_from(tries).map_err(|_| QueueError::Range("tries"))?,
        status: parse_status(row.try_get("status")?)?,
        placement: host.zip(slot).map(|(host, slot)| Placement { host, slot }),
        pins: serde_json::from_value(row.try_get("pins")?)?,
    };
    Ok(Locked {
        attempt,
        cancel_requested: row.try_get("cancel_requested")?,
        retry: RetryPolicy {
            max_attempts: u32::try_from(max_attempts)
                .map_err(|_| QueueError::Range("max_attempts"))?,
        },
        expired: row.try_get::<_, Option<bool>>("expired")?.unwrap_or(false),
        durations: Durations {
            in_state_ms: row.try_get("in_state_ms")?,
            since_submit_ms: row.try_get("since_submit_ms")?,
        },
    })
}

/// Applies `event` to a locked row: the contract's check, then the database's fence, the event and any receipt.
fn write(
    tx: &mut Transaction<'_>,
    row: Locked,
    event: &Event,
    receipt: Option<&Receipt>,
    checkpoint: Option<&CheckpointRef>,
    lease_secs: u32,
) -> Result<(Attempt, Change), QueueError> {
    let mut next = transition(&row.attempt, &row.retry, event)?;
    // a cancel asked of a live attempt that goes back to the queue (an expiry, a prepare that failed, a pause, an
    // operator's requeue), or would but has no attempt left, takes effect there instead of at the next claim
    let requeued = match next.status {
        Status::Queued | Status::Waiting => true,
        Status::Failed => !matches!(
            event.kind,
            Kind::Settle(Settle::Failed) | Kind::Resolve(Resolution::Failed)
        ),
        _ => false,
    };
    if row.cancel_requested && requeued {
        next.status = Status::Cancelled;
    }
    // the settle the holder asked for: a retry that exhaustion turns into a failure has no receipt
    let terminal = matches!(
        event.kind,
        Kind::Settle(
            Settle::Succeeded | Settle::Failed | Settle::NeedsReview | Settle::Interrupted
        )
    );
    if terminal != receipt.is_some() {
        return Err(QueueError::Receipt(next.status));
    }
    if let Some(r) = receipt {
        r.validate()?;
        r.settles(&next)?;
    }
    let placement = next.placement.as_ref();
    let (host, slot) = (placement.map(|p| &p.host), placement.map(|p| &p.slot));
    let deadline = match next.status {
        Status::Leased if matches!(event.kind, Kind::Lease(_)) => "new",
        Status::Leased | Status::Running | Status::Checkpointing => "keep",
        _ => "none",
    };
    let checkpoint = checkpoint
        .or_else(|| receipt.and_then(|r| r.checkpoint.as_ref()))
        .map(serde_json::to_value)
        .transpose()?;
    tx.execute(
        "UPDATE attempts SET status = $2, lease_epoch = $3, tries = $4, host = $5, slot = $6, fence = $7, \
         lease_deadline = CASE $8::text WHEN 'new' THEN now() + make_interval(secs => $9) \
         WHEN 'keep' THEN lease_deadline END, checkpoint = coalesce($10, checkpoint), changed_at = now() \
         WHERE id = $1",
        &[
            &next.id,
            &status_str(next.status),
            &i64_of("lease_epoch", next.lease_epoch)?,
            &i32::try_from(next.tries).map_err(|_| QueueError::Range("tries"))?,
            &host,
            &slot,
            &i64_of("epoch", event.epoch)?,
            &deadline,
            &f64::from(lease_secs),
            &checkpoint,
        ],
    )?;
    let change = Change {
        task_id: next.task_id.clone(),
        attempt: next.id.clone(),
        lease_epoch: next.lease_epoch,
        host: host.cloned(),
        slot: slot.cloned(),
        from: Some(row.attempt.status),
        to: next.status,
        reason: reason(&event.kind, next.status),
        durations: row.durations,
    };
    let event_id = append(tx, &change)?;
    if let Some(r) = receipt {
        tx.execute(
            "INSERT INTO receipts (event_id, attempt_id, lease_epoch, outcome, effects) VALUES ($1, $2, $3, $4, $5)",
            &[
                &event_id,
                &r.attempt_id,
                &i64_of("lease_epoch", r.lease_epoch)?,
                &status_str(next.status),
                &serde_json::to_value(&r.effects)?,
            ],
        )?;
    }
    Ok((next, change))
}

fn append(tx: &mut Transaction<'_>, c: &Change) -> Result<i64, QueueError> {
    let row = tx.query_one(
        "INSERT INTO events (task_id, attempt_id, lease_epoch, from_status, to_status, reason, host, slot, \
         in_state_ms, since_submit_ms) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id",
        &[
            &c.task_id,
            &c.attempt,
            &i64_of("lease_epoch", c.lease_epoch)?,
            &c.from.map(status_str),
            &status_str(c.to),
            &c.reason,
            &c.host,
            &c.slot,
            &c.durations.in_state_ms,
            &c.durations.since_submit_ms,
        ],
    )?;
    Ok(row.try_get(0)?)
}

/// A definer function's "no task of yours" as [`QueueError::NotFound`].
fn not_found(e: postgres::Error, id: &str) -> QueueError {
    match e.as_db_error() {
        Some(db) if db.code() == &SqlState::NO_DATA_FOUND => QueueError::NotFound(id.to_owned()),
        _ => e.into(),
    }
}

fn lock(tx: &mut Transaction<'_>, attempt: &str) -> Result<Locked, QueueError> {
    let rows = tx.query(
        &format!(
            "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id WHERE a.id = $1 FOR UPDATE OF a"
        ),
        &[&attempt],
    )?;
    rows.first()
        .map_or_else(|| Err(QueueError::NotFound(attempt.to_owned())), locked)
}

impl Store {
    /// # Errors
    /// [`QueueError::NotUnixSocket`] unless every host in `conninfo` is a socket directory; a malformed `conninfo`.
    /// Connecting waits for the first call.
    pub fn open(conninfo: &str) -> Result<Self, QueueError> {
        let config = Config::from_str(conninfo).map_err(|e| QueueError::Db {
            code: "conninfo".to_owned(),
            message: e.to_string(),
        })?;
        let hosts = config.get_hosts();
        // a hostaddr would connect over TCP whatever host says
        if hosts.is_empty()
            || hosts.iter().any(|h| !matches!(h, Host::Unix(_)))
            || !config.get_hostaddrs().is_empty()
        {
            return Err(QueueError::NotUnixSocket);
        }
        Ok(Self {
            config,
            client: None,
        })
    }

    /// A queue on another host, for a remote slot's runner (`exec_pool_runner`, by scram over the fleet LAN): every
    /// host in `conninfo` TCP, the password given apart, never in `conninfo`. Connecting waits for the first call.
    ///
    /// # Errors
    /// [`QueueError::NotRemote`] for a socket host or a password in `conninfo`; a malformed `conninfo`.
    pub fn open_remote(conninfo: &str, password: &[u8]) -> Result<Self, QueueError> {
        let mut config = Config::from_str(conninfo).map_err(|e| QueueError::Db {
            code: "conninfo".to_owned(),
            message: e.to_string(),
        })?;
        let hosts = config.get_hosts();
        if hosts.is_empty()
            || hosts.iter().any(|h| !matches!(h, Host::Tcp(_)))
            || config.get_password().is_some()
            || password.is_empty()
        {
            return Err(QueueError::NotRemote);
        }
        config.password(password);
        Ok(Self {
            config,
            client: None,
        })
    }

    fn client(&mut self) -> Result<&mut Client, QueueError> {
        if self.client.as_ref().is_none_or(Client::is_closed) {
            self.client = Some(self.config.connect(NoTls)?);
        }
        self.client
            .as_mut()
            .ok_or_else(|| QueueError::Unavailable("not connected".to_owned()))
    }

    /// Runs `f` in one transaction; a lost connection is dropped so the next call reconnects. Losing it during the
    /// commit is [`QueueError::OutcomeUnknown`].
    fn tx<T>(
        &mut self,
        f: impl FnOnce(&mut Transaction<'_>) -> Result<T, QueueError>,
    ) -> Result<T, QueueError> {
        let result = (|| {
            let mut tx = self.client()?.transaction()?;
            let out = f(&mut tx)?;
            tx.commit().map_err(|e| match QueueError::from(e) {
                QueueError::Unavailable(m) => QueueError::OutcomeUnknown(m),
                other => other,
            })?;
            Ok(out)
        })();
        if matches!(
            result,
            Err(QueueError::Unavailable(_) | QueueError::OutcomeUnknown(_) | QueueError::Client(_))
        ) {
            self.client = None;
        }
        result
    }

    fn version(c: &mut impl GenericClient) -> Result<Option<i32>, QueueError> {
        let row = c.query_one("SELECT to_regclass('schema_migrations') IS NOT NULL", &[])?;
        if !row.try_get::<_, bool>(0)? {
            return Ok(None);
        }
        Ok(
            c.query_one("SELECT max(version) FROM schema_migrations", &[])?
                .try_get(0)?,
        )
    }

    /// Applies the migrations the database lacks; refuses a database a newer binary migrated past this one's floor.
    ///
    /// # Errors
    /// [`QueueError::SchemaAhead`], or what the database reports.
    pub fn migrate(&mut self) -> Result<(), QueueError> {
        self.tx(|tx| {
            // two first migrations at once would both see no schema
            tx.execute("SELECT pg_advisory_xact_lock(651)", &[])?;
            let done = Self::version(tx)?.unwrap_or(0);
            // ahead of VERSION, the database has 0007's floor column
            if done > VERSION
                && tx
                    .query_one(
                        "SELECT max(coalesce(floor, version)) FROM schema_migrations",
                        &[],
                    )?
                    .try_get::<_, i32>(0)?
                    > VERSION
            {
                return Err(QueueError::SchemaAhead(done));
            }
            let applied = if done == 0 {
                Vec::new()
            } else {
                tx.query("SELECT version FROM schema_migrations", &[])?
                    .iter()
                    .map(|r| r.try_get::<_, i32>(0))
                    .collect::<Result<Vec<_>, _>>()?
            };
            STEPS
                .iter()
                .filter(|(v, _)| !applied.contains(v))
                .try_for_each(|(_, step)| Ok(tx.batch_execute(step)?))
        })
    }

    /// Drops the schema and all queue data: the rollback for a database this binary migrated.
    ///
    /// # Errors
    /// [`QueueError::SchemaAhead`], [`QueueError::NotMigrated`], or what the database reports.
    pub fn migrate_down(&mut self) -> Result<(), QueueError> {
        self.tx(|tx| match Self::version(tx)? {
            None => Err(QueueError::NotMigrated),
            Some(v) if v > VERSION => Err(QueueError::SchemaAhead(v)),
            Some(_) => Ok(tx.batch_execute(&format!(
                "{DOWN_UNDELIVERED}{DOWN_TRANSCRIPT}{DOWN_PRIORITY}{DOWN_TURN_LOG}{DOWN_TIMER}{DOWN_DRAIN_REASON}{DOWN_CLAIM_HOST}{DOWN_SESSION_METRICS}{DOWN_SESSION}{DOWN_SLOTS}{DOWN_QUARANTINE}{DOWN_CANCEL}{DOWN_RESULT}{DOWN_SUBMITTER}{DOWN}"
            ))?),
        })
    }

    /// Queues `task` through `submit_task`, as `exec_pool_submit` may: the queue assigns its id from its key and refuses
    /// any task but the shape `exec-pool submit` builds; `priority` (-100 to 100, higher claimed first) is kept from
    /// its first submission. The queued task's id and whether it was already queued.
    ///
    /// # Errors
    /// What `submit_task` or the database reports, an idempotency conflict included.
    pub fn submit_task(
        &mut self,
        task: &TaskSpec,
        priority: i32,
    ) -> Result<(String, bool), QueueError> {
        self.queue_through("submit_task", task, priority)
    }

    /// Starts `task`, a claude task in the shape [`Store::submit_task`] takes, as a session through `start_session`:
    /// its first turn runs the prompt, and each later one what [`Store::send`] put in its inbox. Every turn is claimed at
    /// `priority`, as there.
    ///
    /// # Errors
    /// What `start_session` or the database reports: an agent other than claude, or a key that names a one-shot task.
    pub fn start_session(
        &mut self,
        task: &TaskSpec,
        priority: i32,
    ) -> Result<(String, bool), QueueError> {
        self.queue_through("start_session", task, priority)
    }

    fn queue_through(
        &mut self,
        function: &'static str,
        task: &TaskSpec,
        priority: i32,
    ) -> Result<(String, bool), QueueError> {
        let mut spec = serde_json::to_value(task)?;
        if let Value::Object(m) = &mut spec {
            m.remove("id");
        }
        self.tx(|tx| {
            let row = tx.query_one(
                &format!("SELECT o_task, o_duplicate FROM {function}($1, $2)"),
                &[&spec, &priority],
            )?;
            Ok((row.try_get(0)?, row.try_get(1)?))
        })
    }

    /// Queues `task` with one attempt, or returns the attempt it already has under its key.
    ///
    /// # Errors
    /// [`Error::IdempotencyConflict`] when the key names a different task, or what the database reports.
    pub fn submit(&mut self, task: &TaskSpec) -> Result<Submitted, QueueError> {
        let spec = serde_json::to_value(task)?;
        let attempt = format!("{}.a", task.id);
        self.tx(|tx| {
            let max = i32::try_from(task.retry.max_attempts)
                .map_err(|_| QueueError::Range("max_attempts"))?;
            let inserted = tx.execute(
                "INSERT INTO tasks (id, idempotency_key, spec, max_attempts) VALUES ($1, $2, $3, $4) \
                 ON CONFLICT (idempotency_key) DO NOTHING",
                &[&task.id, &task.idempotency_key, &spec, &max],
            )?;
            if inserted == 0 {
                let row = tx.query_one(
                    "SELECT t.spec, a.id FROM tasks t JOIN attempts a ON a.task_id = t.id \
                     WHERE t.idempotency_key = $1",
                    &[&task.idempotency_key],
                )?;
                let known: TaskSpec = serde_json::from_value(row.try_get(0)?)?;
                return if &known == task {
                    Ok(Submitted::Duplicate {
                        attempt: row.try_get(1)?,
                    })
                } else {
                    Err(Error::IdempotencyConflict(task.idempotency_key.clone()).into())
                };
            }
            tx.execute(
                "INSERT INTO attempts (id, task_id) VALUES ($1, $2)",
                &[&attempt, &task.id],
            )?;
            let change = Change {
                task_id: task.id.clone(),
                attempt: attempt.clone(),
                lease_epoch: 0,
                host: None,
                slot: None,
                from: None,
                to: Status::Queued,
                reason: "submit",
                durations: Durations {
                    in_state_ms: 0,
                    since_submit_ms: 0,
                },
            };
            append(tx, &change)?;
            Ok(Submitted::New { attempt, change })
        })
    }

    /// Leases the queued attempt that fits `slot` for `lease_secs` with the highest priority, its task's plus one for
    /// every 10 minutes it has waited, the oldest among equals, skipping rows another claimer holds. A live one is never
    /// stopped for it. Any host may take a session's turn: its work is on its remote and its transcript here.
    ///
    /// # Errors
    /// What [`Slot::validate`] rejects, or what the database reports (a slot with a live lease already included).
    pub fn claim(&mut self, slot: &Slot, lease_secs: u32) -> Result<Option<Claim>, QueueError> {
        slot.validate()?;
        if lease_secs == 0 {
            return Err(QueueError::Range("lease_secs"));
        }
        let agents = serde_json::to_value(&slot.agents)?;
        self.tx(|tx| {
            // the agents submit_task checks a task against (0008_slots.up.sql)
            tx.execute(
                "INSERT INTO slots (host, id, agents) VALUES ($1, $2, $3) \
                 ON CONFLICT (host, id) DO UPDATE SET agents = excluded.agents, seen_at = now()",
                &[&slot.host, &slot.id, &agents],
            )?;
            // read every queued task unlocked, then lock only the one taken, so a claimer holds no row it skips; a
            // session's checkpoint as it was read
            let candidates = tx.query(
                &format!(
                    "SELECT a.id, t.spec, a.checkpoint FROM attempts a JOIN tasks t ON t.id = a.task_id \
                     WHERE a.status = 'queued' ORDER BY {CLAIM_ORDER}"
                ),
                &[],
            )?;
            for candidate in &candidates {
                let task: TaskSpec = serde_json::from_value(candidate.try_get(1)?)?;
                let raw: Option<Value> = candidate.try_get(2)?;
                // one this runner cannot read is not its to take, and does not stop it taking another
                let Ok(checkpoint) = raw
                    .clone()
                    .map(serde_json::from_value::<CheckpointRef>)
                    .transpose()
                else {
                    continue;
                };
                if task.fits(slot).is_err() {
                    continue;
                }
                let id: &str = candidate.try_get(0)?;
                let rows = tx.query(
                    &format!(
                        "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id \
                         WHERE a.id = $1 AND a.status = 'queued' AND a.checkpoint IS NOT DISTINCT FROM $2 \
                         FOR UPDATE OF a SKIP LOCKED"
                    ),
                    &[&id, &raw],
                )?;
                let Some(row) = rows.first() else { continue };
                let row = locked(row)?;
                let event = Event {
                    epoch: row.attempt.lease_epoch,
                    kind: Kind::Lease(Placement {
                        host: slot.host.clone(),
                        slot: slot.id.clone(),
                    }),
                };
                let (attempt, change) = write(tx, row, &event, None, None, lease_secs)?;
                let turn = turn(tx, &task, &attempt.id, checkpoint)?;
                return Ok(Some(Claim {
                    task,
                    attempt,
                    change,
                    turn,
                }));
            }
            Ok(None)
        })
    }

    /// The attempt holding a live lease on `slot`, if any: how a claimer that got [`QueueError::OutcomeUnknown`]
    /// learns whether its claim landed, and at which epoch.
    ///
    /// # Errors
    /// What the database reports.
    pub fn live_on(&mut self, slot: &Slot) -> Result<Option<Attempt>, QueueError> {
        self.tx(|tx| {
            let rows = tx.query(
                &format!(
                    "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id \
                     WHERE a.host = $1 AND a.slot = $2 AND a.status IN {LIVE}"
                ),
                &[&slot.host, &slot.id],
            )?;
            rows.first()
                .map(|r| locked(r).map(|l| l.attempt))
                .transpose()
        })
    }

    /// Applies one event from the holder (start, checkpoint, settle) or the operator (wake, resolve); a lease is
    /// [`Store::claim`]'s, an expiry [`Store::reconcile`]'s and a park [`Store::park`]'s. A holder's event after its lease deadline is refused:
    /// the lease is the reconciler's to expire.
    ///
    /// # Errors
    /// [`Error::IllegalTransition`] for a lease or an expiry, [`QueueError::NotLive`], [`QueueError::Receipt`], what [`transition`] or [`Receipt::settles`] rejects, or
    /// what the database reports, its fence included.
    pub fn apply(
        &mut self,
        attempt: &str,
        event: &Event,
        receipt: Option<&Receipt>,
    ) -> Result<(Attempt, Change), QueueError> {
        self.tx(|tx| {
            let row = lock(tx, attempt)?;
            if matches!(event.kind, Kind::Lease(_) | Kind::Expire | Kind::Park(_)) {
                return Err(Error::IllegalTransition {
                    from: row.attempt.status,
                    event: "lease, expire or park outside claim, reconcile and park",
                }
                .into());
            }
            let holder = matches!(event.kind, Kind::Start | Kind::Checkpoint | Kind::Settle(_));
            if holder && row.expired && event.epoch == row.attempt.lease_epoch {
                return Err(QueueError::NotLive(attempt.to_owned()));
            }
            write(tx, row, event, receipt, None, 0)
        })
    }

    /// Ends a session's turn at `epoch`, in one transaction: running or checkpointing to `waiting` with the try given
    /// back and the slot freed, `park.checkpoint` and `park.result` recorded, the inbox rows up to `park.upto` marked
    /// read at `epoch`; a turn preempted, stopped for a draining host or timed out (up to [`TIMEOUTS_IN_A_ROW`]) leaves a
    /// `continue` row, and `park.wake` a
    /// timer row (a `turn_end` with one parks as `waiting_until`). Then, if an unread row is due, the session is queued
    /// for its next turn. Every change, in order.
    ///
    /// # Errors
    /// [`QueueError::NotSession`] for a one-shot task, [`QueueError::NotLive`] past the lease deadline, what
    /// [`transition`] or [`Wake::new`] rejects (a stale epoch included), or what the database reports.
    pub fn park(
        &mut self,
        attempt: &str,
        epoch: u64,
        park: &Park,
    ) -> Result<(Attempt, Vec<Change>), QueueError> {
        let checkpoint = park
            .checkpoint
            .as_ref()
            .map(|c| {
                c.validate().map(|()| CheckpointRef {
                    generation: epoch,
                    ..c.clone()
                })
            })
            .transpose()?;
        let wake = park
            .wake
            .as_ref()
            .map(|w| Wake::new(&w.due_at, w.note.clone()))
            .transpose()?;
        let reason = match (park.reason, &wake) {
            (ParkReason::TurnEnd, Some(_)) => ParkReason::WaitingUntil,
            (r, _) => r,
        };
        self.tx(|tx| {
            let row = lock(tx, attempt)?;
            if row.expired && epoch == row.attempt.lease_epoch {
                return Err(QueueError::NotLive(attempt.to_owned()));
            }
            let task = row.attempt.task_id.clone();
            let session: bool = tx
                .query_one("SELECT session FROM tasks WHERE id = $1", &[&task])?
                .try_get(0)?;
            if !session {
                return Err(QueueError::NotSession(attempt.to_owned()));
            }
            let event = Event {
                epoch,
                kind: Kind::Park(reason),
            };
            let (mut parked, change) = write(tx, row, &event, None, checkpoint.as_ref(), 0)?;
            let mut changes = vec![change];
            let epoch = i64_of("epoch", epoch)?;
            insert_result(tx, attempt, epoch, &park.result)?;
            put_transcript(tx, &task, epoch, park.transcript.as_ref())?;
            let usage = park.result.usage;
            let tokens = |f: fn(&crate::task_result::Usage) -> u64| {
                usage.as_ref().map(|u| i64_of("tokens", f(u))).transpose()
            };
            tx.execute(
                "INSERT INTO turns (attempt_id, lease_epoch, input_tokens, output_tokens, cache_read_tokens, \
                 cache_creation_tokens, cost_usd, handed_back, delivered) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                &[
                    &attempt,
                    &epoch,
                    &tokens(|u| u.input_tokens)?,
                    &tokens(|u| u.output_tokens)?,
                    &tokens(|u| u.cache_read_tokens)?,
                    &tokens(|u| u.cache_creation_tokens)?,
                    &usage.and_then(|u| u.cost_usd),
                    &park.result.handed_back,
                    &!park.undelivered,
                ],
            )?;
            mark_read(tx, (&task, attempt, epoch), park)?;
            let resume = match park.reason {
                ParkReason::Preempted | ParkReason::HostDraining => true,
                ParkReason::TurnTimeout => timeouts_in_a_row(tx, &task, attempt)? < TIMEOUTS_IN_A_ROW,
                _ => false,
            };
            if resume {
                tx.execute(
                    "INSERT INTO inbox (task_id, kind) VALUES ($1, 'continue')",
                    &[&task],
                )?;
            }
            if let Some(w) = &wake {
                tx.execute(
                    "SELECT wake_at($1, $2::text::timestamptz, $3)",
                    &[&task, &w.due_at, &w.note],
                )?;
            }
            let due: bool = tx
                .query_one(
                    "SELECT EXISTS (SELECT FROM inbox WHERE task_id = $1 AND consumed_epoch IS NULL \
                     AND (due_at IS NULL OR due_at <= now()))",
                    &[&task],
                )?
                .try_get(0)?;
            if due && parked.status == Status::Waiting {
                let row = lock(tx, attempt)?;
                let wake = Event {
                    epoch: parked.lease_epoch,
                    kind: Kind::Wake,
                };
                let (woken, change) = write(tx, row, &wake, None, None, 0)?;
                parked = woken;
                changes.push(change);
            }
            Ok((parked, changes))
        })
    }

    /// What a live session turn's runner tells its helper: the session's unread messages after `upto` (what the claim
    /// handed over), by id, and whether work waits for a slot (a queued attempt, and no idle slot on any host).
    ///
    /// # Errors
    /// What the database reports.
    pub fn during_turn(
        &mut self,
        task_id: &str,
        upto: i64,
    ) -> Result<(Vec<(i64, String)>, bool), QueueError> {
        self.tx(|tx| {
            let mail = tx
                .query(
                    "SELECT id, body FROM inbox WHERE task_id = $1 AND id > $2 AND kind = 'message' \
                     AND consumed_epoch IS NULL ORDER BY id",
                    &[&task_id, &upto],
                )?
                .iter()
                .map(|r| Ok((r.try_get(0)?, r.try_get(1)?)))
                .collect::<Result<Vec<_>, postgres::Error>>()?;
            let busy: bool = tx
                .query_one(
                    &format!(
                        "SELECT EXISTS (SELECT FROM attempts WHERE status = 'queued') \
                         AND NOT EXISTS ({IDLE_SLOTS})"
                    ),
                    &[],
                )?
                .try_get(0)?;
            Ok((mail, busy))
        })
    }

    /// Extends a live lease to `lease_secs` from now; whether its submitter asked to cancel it.
    ///
    /// # Errors
    /// [`QueueError::NotLive`] when the attempt has no unexpired lease, [`QueueError::Fenced`] at a stale epoch.
    pub fn heartbeat(
        &mut self,
        attempt: &str,
        epoch: u64,
        lease_secs: u32,
    ) -> Result<bool, QueueError> {
        if lease_secs == 0 {
            return Err(QueueError::Range("lease_secs"));
        }
        self.tx(|tx| {
            let rows = tx.query(
                &format!(
                    "UPDATE attempts SET lease_deadline = now() + make_interval(secs => $3), fence = $2 \
                     WHERE id = $1 AND status IN {LIVE} AND lease_deadline > clock_timestamp() \
                     RETURNING cancel_requested"
                ),
                &[&attempt, &i64_of("epoch", epoch)?, &f64::from(lease_secs)],
            )?;
            rows.first().map_or_else(
                || Err(QueueError::NotLive(attempt.to_owned())),
                |r| Ok(r.try_get(0)?),
            )
        })
    }

    /// Cancels the task `id` names (its own id or its attempt's) through `cancel_task`, which `exec_pool_submit` may
    /// call for the tasks it queued: a queued or waiting attempt is cancelled at once, a live one is marked for its
    /// runner to stop and settle, anything else is left. The attempt and its status after the call.
    ///
    /// # Errors
    /// [`QueueError::NotFound`] when the caller queued no task `id` names, or what the database reports.
    pub fn cancel(&mut self, id: &str) -> Result<(String, Status), QueueError> {
        self.tx(|tx| {
            let row = tx
                .query_one("SELECT o_attempt, o_status FROM cancel_task($1)", &[&id])
                .map_err(|e| not_found(e, id))?;
            Ok((row.try_get(0)?, parse_status(row.try_get(1)?)?))
        })
    }

    /// Puts `body` in the inbox of the session `id` names (its own id or its attempt's) through `send_message`, which
    /// `exec_pool_submit` may call for the sessions it started: a waiting or `needs_review` session is queued for its
    /// next turn, a queued or live one takes it at the turn after its current one. The attempt and its status after.
    ///
    /// # Errors
    /// [`QueueError::NotFound`] when the caller started no task `id` names; what the database reports for a one-shot
    /// task, a settled session or an empty `body`.
    pub fn send(&mut self, id: &str, body: &str) -> Result<(String, Status), QueueError> {
        self.tx(|tx| {
            let row = tx
                .query_one(
                    "SELECT o_attempt, o_status FROM send_message($1, $2)",
                    &[&id, &body],
                )
                .map_err(|e| not_found(e, id))?;
            Ok((row.try_get(0)?, parse_status(row.try_get(1)?)?))
        })
    }

    /// Puts a timer row in the inbox of the session `id` names through `send_timer`, as [`Store::send`] a message: it
    /// is delivered once `due_at` (RFC 3339 with an offset) has passed, and only then queues a waiting session
    /// ([`Store::reconcile`]). The attempt and its status, unchanged.
    ///
    /// # Errors
    /// What [`Store::send`] reports, and what the database makes of `due_at`.
    pub fn send_timer(
        &mut self,
        id: &str,
        body: &str,
        due_at: &str,
    ) -> Result<(String, Status), QueueError> {
        self.tx(|tx| {
            let row = tx
                .query_one(
                    "SELECT o_attempt, o_status FROM send_timer($1, $2, $3::text::timestamptz)",
                    &[&id, &body, &due_at],
                )
                .map_err(|e| not_found(e, id))?;
            Ok((row.try_get(0)?, parse_status(row.try_get(1)?)?))
        })
    }

    /// Expires every lease past its deadline: a lease that never started goes back to queued (or fails with no
    /// attempt left), a started one to `needs_review`. Then queues every waiting session an unread inbox row is due
    /// for: a timer whose time came. Run at startup and on a timer.
    ///
    /// # Errors
    /// What the database reports.
    pub fn reconcile(&mut self) -> Result<Vec<Change>, QueueError> {
        self.tx(|tx| {
            let mut changes = Vec::new();
            for (filter, kind) in [
                (
                    format!("a.status IN {LIVE} AND a.lease_deadline <= now()"),
                    Kind::Expire,
                ),
                (
                    "t.session AND a.status = 'waiting' AND EXISTS (SELECT FROM inbox i WHERE i.task_id = t.id \
                     AND i.consumed_epoch IS NULL AND (i.due_at IS NULL OR i.due_at <= now()))"
                        .to_owned(),
                    Kind::Wake,
                ),
            ] {
                let rows = tx.query(
                    &format!(
                        "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id \
                         WHERE {filter} FOR UPDATE OF a SKIP LOCKED"
                    ),
                    &[],
                )?;
                for row in &rows {
                    let row = locked(row)?;
                    let event = Event {
                        epoch: row.attempt.lease_epoch,
                        kind: kind.clone(),
                    };
                    changes.push(write(tx, row, &event, None, None, 0)?.1);
                }
            }
            Ok(changes)
        })
    }

    /// The task `id` names (its own id or its attempt's), its attempt's state and its events oldest first; no
    /// prompt. `None` when no task has that id.
    ///
    /// # Errors
    /// What the database reports.
    pub fn task(&mut self, id: &str) -> Result<Option<Value>, QueueError> {
        self.tx(|tx| {
            let rows = tx.query(
                &format!(
                    "SELECT {SUMMARY} || jsonb_build_object('events', (SELECT coalesce(jsonb_agg(jsonb_build_object( \
                     'at', e.at, 'from', e.from_status, 'to', e.to_status, 'reason', e.reason, \
                     'lease_epoch', e.lease_epoch, 'host', e.host, 'slot', e.slot) ORDER BY e.id), '[]') \
                     FROM events e WHERE e.attempt_id = a.id)) \
                     FROM task_summaries t JOIN attempts a ON a.task_id = t.id WHERE t.id = $1 OR a.id = $1"
                ),
                &[&id],
            )?;
            rows.first().map(|r| r.try_get(0)).transpose().map_err(Into::into)
        })
    }

    /// Records what attempt `attempt` produced at `epoch`, once a settle took it off its slot: a later epoch's result
    /// replaces an earlier one, and the same epoch's again changes nothing. Whether it was recorded.
    ///
    /// # Errors
    /// [`QueueError::Fenced`] while the attempt is live or at another epoch, or what the database reports.
    pub fn record_result(
        &mut self,
        attempt: &str,
        epoch: u64,
        result: &TaskResult,
    ) -> Result<bool, QueueError> {
        self.tx(|tx| insert_result(tx, attempt, i64_of("epoch", epoch)?, result))
    }

    /// Puts the tail of attempt `attempt`'s output at `epoch` ([`crate::turn_log::read`]), `start` its offset, in place
    /// of what the queue held of it, while the attempt is at that epoch; an older tail than the one held changes nothing.
    ///
    /// # Errors
    /// [`QueueError::Fenced`] when the attempt is at another epoch, or what the database reports (a log over the bound).
    pub fn put_log(
        &mut self,
        attempt: &str,
        epoch: u64,
        start: u64,
        log: &[u8],
    ) -> Result<(), QueueError> {
        self.tx(|tx| {
            let n = tx.execute(
                "INSERT INTO turn_logs (attempt_id, lease_epoch, start, log) \
                 SELECT id, lease_epoch, $3, $4 FROM attempts WHERE id = $1 AND lease_epoch = $2 \
                 ON CONFLICT (attempt_id, lease_epoch) DO UPDATE SET start = EXCLUDED.start, log = EXCLUDED.log, \
                 updated_at = now() WHERE turn_logs.start <= EXCLUDED.start",
                &[&attempt, &i64_of("epoch", epoch)?, &i64_of("start", start)?, &log],
            )?;
            if n == 0 && tx.query_opt(
                "SELECT 1 FROM attempts WHERE id = $1 AND lease_epoch = $2",
                &[&attempt, &i64_of("epoch", epoch)?],
            )?.is_none() {
                return Err(QueueError::Fenced(format!("attempt {attempt} is not at epoch {epoch}")));
            }
            Ok(())
        })
    }

    /// The log of turn `turn` (from 1, in lease order, of the turns that logged; `None`: the last) of the task `id`
    /// names (its own id or its attempt's), and whether its attempt is still queued or live, so more may come.
    ///
    /// # Errors
    /// [`QueueError::NotFound`] when no task has that id, or what the database reports.
    pub fn logs(&mut self, id: &str, turn: Option<u32>) -> Result<Logs, QueueError> {
        self.tx(|tx| {
            let attempt = tx
                .query_opt(
                    &format!(
                        "SELECT id, status = 'queued' OR status IN {LIVE} FROM attempts WHERE task_id = $1 OR id = $1 \
                         ORDER BY task_id = $1 DESC LIMIT 1"
                    ),
                    &[&id],
                )?
                .ok_or_else(|| QueueError::NotFound(id.to_owned()))?;
            let (attempt, pending): (String, bool) = (attempt.try_get(0)?, attempt.try_get(1)?);
            let row = tx.query_opt(
                &format!(
                    "SELECT l.n, l.turns, l.lease_epoch, l.start, l.log, \
                     a.lease_epoch = l.lease_epoch AND a.status IN {LIVE} \
                     FROM attempts a JOIN (SELECT *, row_number() OVER w AS n, count(*) OVER () AS turns \
                       FROM turn_logs WHERE attempt_id = $1 WINDOW w AS (ORDER BY lease_epoch)) l ON l.attempt_id = a.id \
                     WHERE a.id = $1 AND l.n = coalesce($2, l.turns)"
                ),
                &[&attempt, &turn.map(i64::from)],
            )?;
            let turn = row
                .map(|r| {
                    Ok::<_, QueueError>(TurnLog {
                        turn: u64_of("turn", r.try_get(0)?)?,
                        turns: u64_of("turns", r.try_get(1)?)?,
                        lease_epoch: u64_of("lease_epoch", r.try_get(2)?)?,
                        start: u64_of("start", r.try_get(3)?)?,
                        log: r.try_get(4)?,
                        live: r.try_get(5)?,
                    })
                })
                .transpose()?;
            Ok(Logs { pending, turn })
        })
    }

    /// Records `slot` as quarantined for `reason` (its first 1024 characters), or updates the reason it already has.
    ///
    /// # Errors
    /// What the database reports.
    pub fn quarantine(&mut self, slot: &Slot, reason: &str) -> Result<(), QueueError> {
        self.tx(|tx| {
            tx.execute(
                "INSERT INTO quarantined_slots (host, slot, reason) VALUES ($1, $2, left($3, 1024)) \
                 ON CONFLICT (host, slot) DO UPDATE SET reason = EXCLUDED.reason",
                &[&slot.host, &slot.id, &reason],
            )?;
            Ok(())
        })
    }

    /// Clears `slot`'s quarantine, once a reset succeeded; none is no change.
    ///
    /// # Errors
    /// What the database reports.
    pub fn clear_quarantine(&mut self, slot: &Slot) -> Result<(), QueueError> {
        self.tx(|tx| {
            tx.execute(
                "DELETE FROM quarantined_slots WHERE host = $1 AND slot = $2",
                &[&slot.host, &slot.id],
            )?;
            Ok(())
        })
    }

    /// The task `id` names, as [`Store::tasks`] shows it, with the `result` recorded at its attempt's current epoch,
    /// or for a session at its last parked turn (`null` before one);
    /// no prompt. `None` when no task has that id.
    ///
    /// # Errors
    /// What the database reports.
    pub fn result(&mut self, id: &str) -> Result<Option<Value>, QueueError> {
        self.tx(|tx| {
            let rows = tx.query(
                &format!(
                    "SELECT {SUMMARY} || jsonb_build_object('result', CASE WHEN r.attempt_id IS NOT NULL THEN \
                     jsonb_build_object('lease_epoch', r.lease_epoch, 'outcome', r.outcome, \
                     'exit_code', r.exit_code, 'output', r.output, 'branch', r.branch, 'recorded_at', r.recorded_at) END) \
                     FROM task_summaries t JOIN attempts a ON a.task_id = t.id \
                     LEFT JOIN results r ON r.attempt_id = a.id AND (r.lease_epoch = a.lease_epoch OR t.session) WHERE t.id = $1 OR a.id = $1"
                ),
                &[&id],
            )?;
            rows.first().map(|r| r.try_get(0)).transpose().map_err(Into::into)
        })
    }

    /// The newest `limit` tasks, newest first, as [`Store::task`] shows them without their events.
    ///
    /// # Errors
    /// What the database reports.
    pub fn tasks(&mut self, limit: i64) -> Result<Vec<Value>, QueueError> {
        self.tx(|tx| {
            tx.query(
                &format!(
                    "SELECT {SUMMARY} FROM task_summaries t JOIN attempts a ON a.task_id = t.id \
                     ORDER BY t.submitted_at DESC, t.id LIMIT $1"
                ),
                &[&limit],
            )?
            .iter()
            .map(|r| Ok(r.try_get(0)?))
            .collect()
        })
    }

    /// How many attempts are in each status, statuses with none left out.
    ///
    /// # Errors
    /// What the database reports.
    pub fn counts(&mut self) -> Result<Value, QueueError> {
        self.tx(|tx| {
            Ok(tx
                .query_one(
                    "SELECT coalesce(jsonb_object_agg(status, n), '{}') \
                     FROM (SELECT status, count(*) AS n FROM attempts GROUP BY status) s",
                    &[],
                )?
                .try_get(0)?)
        })
    }

    /// The queue's counters in the Prometheus text format, for a textfile collector. Labels are hosts, states, agent
    /// kinds and reason codes only. `host` is a slot's host from the queue's own rows (`none` for an attempt before
    /// its first lease, or an event no host wrote), so one host renders every host's series. When it fails for any
    /// reason, render [`METRICS_UNAVAILABLE`] instead.
    ///
    /// # Errors
    /// What the database reports.
    pub fn metrics(&mut self) -> Result<String, QueueError> {
        self.tx(|tx| {
            // one snapshot, so busy slots, counts and histograms agree within a scrape
            tx.batch_execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")?;
            let hosts = slot_hosts(tx)?;
            let mut out = String::from(
                concat!(
                    up_help!(),
                    "exec_pool_queue_up 1\n\
                     # HELP exec_pool_attempts Attempts by state, agent kind and the host each holds or last ran on (one per task).\n\
                     # TYPE exec_pool_attempts gauge\n",
                ),
            );
            let counts = tx.query(
                &format!(
                    "SELECT coalesce({LAST_HOST}, 'none'), a.status, t.spec->'command'->>'agent', count(*) \
                     FROM attempts a JOIN tasks t ON t.id = a.task_id GROUP BY 1, 2, 3"
                ),
                &[],
            )?;
            for host in with_none(&hosts) {
                for s in STATUSES {
                    let state = status_str(s);
                    for agent in AGENTS {
                        let mut n = 0_i64;
                        for r in &counts {
                            if r.try_get::<_, &str>(0)? == host
                                && r.try_get::<_, &str>(1)? == state
                                && r.try_get::<_, Option<&str>>(2)? == Some(agent)
                            {
                                n = r.try_get(3)?;
                            }
                        }
                        let _ = writeln!(
                            out,
                            "exec_pool_attempts{{host=\"{host}\",state=\"{state}\",agent=\"{agent}\"}} {n}"
                        );
                    }
                }
            }
            let row = tx.query_one(
                &format!(
                    "SELECT coalesce(extract(epoch FROM now() - min(a.changed_at)), 0)::float8, \
                     coalesce(extract(epoch FROM now() - min(a.changed_at) FILTER (WHERE EXISTS ( \
                     SELECT FROM ({IDLE_SLOTS}) s WHERE s.agents ? (t.spec->'command'->>'agent')))), 0)::float8 \
                     FROM attempts a JOIN tasks t ON t.id = a.task_id WHERE a.status = 'queued'"
                ),
                &[],
            )?;
            let (oldest, claimable): (f64, f64) = (row.try_get(0)?, row.try_get(1)?);
            let _ = write!(
                out,
                "# HELP exec_pool_queued_oldest_seconds Age of the oldest queued attempt (0 with none).\n\
                 # TYPE exec_pool_queued_oldest_seconds gauge\nexec_pool_queued_oldest_seconds {oldest}\n\
                 # HELP exec_pool_queued_claimable_oldest_seconds Age of the oldest queued attempt whose agent an idle slot offers (0 with none).\n\
                 # TYPE exec_pool_queued_claimable_oldest_seconds gauge\nexec_pool_queued_claimable_oldest_seconds {claimable}\n"
            );
            waiting(tx, &mut out, &hosts)?;
            sessions(tx, &mut out, &hosts)?;
            leases(tx, &mut out, &hosts)?;
            histogram(
                tx,
                &mut out,
                "exec_pool_queue_wait_seconds",
                "# HELP exec_pool_queue_wait_seconds Time from queued to leased, by host and agent kind.\n\
                 # TYPE exec_pool_queue_wait_seconds histogram\n",
                ("queued", "leased"),
                &hosts,
            )?;
            histogram(
                tx,
                &mut out,
                "exec_pool_run_seconds",
                "# HELP exec_pool_run_seconds Time running until a checkpoint, by host and agent kind; an expiry is not a run.\n\
                 # TYPE exec_pool_run_seconds histogram\n",
                ("running", "checkpointing"),
                &hosts,
            )?;
            transitions(tx, &mut out)?;
            Ok(out)
        })
    }
}

/// Records `result` at `epoch` once the attempt is off its slot at that epoch; whether it replaced what was there.
fn insert_result(
    tx: &mut Transaction<'_>,
    attempt: &str,
    epoch: i64,
    result: &TaskResult,
) -> Result<bool, QueueError> {
    let outcome = result
        .outcome
        .map(serde_json::to_value)
        .transpose()?
        .and_then(|v| v.as_str().map(str::to_owned));
    let settled = tx.query(
        &format!(
            "SELECT 1 FROM attempts WHERE id = $1 AND lease_epoch = $2 AND status NOT IN {LIVE} FOR SHARE"
        ),
        &[&attempt, &epoch],
    )?;
    if settled.is_empty() {
        return Err(QueueError::Fenced(format!(
            "attempt {attempt} is not settled at epoch {epoch}"
        )));
    }
    let n = tx.execute(
        "INSERT INTO results (attempt_id, lease_epoch, outcome, exit_code, output, branch) \
         VALUES ($1, $2, $3, $4, $5, $6) \
         ON CONFLICT (attempt_id) DO UPDATE SET lease_epoch = EXCLUDED.lease_epoch, outcome = EXCLUDED.outcome, \
         exit_code = EXCLUDED.exit_code, output = EXCLUDED.output, branch = EXCLUDED.branch, \
         recorded_at = now() \
         WHERE results.lease_epoch < EXCLUDED.lease_epoch",
        &[
            &attempt,
            &epoch,
            &outcome,
            &result.exit_code,
            &result.output(),
            &result.branch,
        ],
    )?;
    Ok(n == 1)
}

/// The turn a claim of `task` at `attempt` hands over, if `task` is a session: its prompt the first time, after that
/// its unread inbox rows that are due.
fn turn(
    tx: &mut Transaction<'_>,
    task: &TaskSpec,
    attempt: &str,
    checkpoint: Option<CheckpointRef>,
) -> Result<Option<Turn>, QueueError> {
    let row = tx.query_one(
        "SELECT session, session_uuid::text, NOT EXISTS (SELECT FROM events e \
         WHERE e.attempt_id = $2 AND e.to_status = 'running' AND NOT EXISTS (SELECT FROM turns u \
         WHERE u.attempt_id = e.attempt_id AND u.lease_epoch = e.lease_epoch AND NOT u.delivered)) \
         FROM tasks WHERE id = $1",
        &[&task.id, &attempt],
    )?;
    if !row.try_get::<_, bool>(0)? {
        return Ok(None);
    }
    let session_uuid = row.try_get(1)?;
    let first: bool = row.try_get(2)?;
    if first {
        return Ok(Some(Turn {
            session_uuid,
            input: task.command.argv.first().cloned().unwrap_or_default(),
            upto: 0,
            first,
            checkpoint,
            transcript: None,
        }));
    }
    let parked: Option<String> = tx
        .query_opt(
            "SELECT reason FROM events WHERE attempt_id = $1 AND to_status = 'waiting' \
             ORDER BY id DESC LIMIT 1",
            &[&attempt],
        )?
        .map(|r| r.try_get(0))
        .transpose()?;
    let stopped = match parked.as_deref() {
        Some("host_draining") => DRAINED,
        Some("turn_timeout") => TIMED_OUT,
        _ => CONTINUE,
    };
    let transcript = tx
        .query_opt(
            "SELECT project, body FROM transcripts WHERE task_id = $1",
            &[&task.id],
        )?
        .map(|r| {
            Ok::<_, QueueError>(Transcript {
                project: r.try_get(0)?,
                body: r.try_get(1)?,
            })
        })
        .transpose()?;
    let mut input = String::new();
    let mut upto = 0;
    // a stopped turn's continue goes first, though what that turn was told is older than it
    for r in tx.query(
        "SELECT id, kind, body FROM inbox WHERE task_id = $1 AND consumed_epoch IS NULL \
         AND (due_at IS NULL OR due_at <= now()) ORDER BY kind <> 'continue', id",
        &[&task.id],
    )? {
        let (id, kind, body): (i64, &str, Option<&str>) =
            (r.try_get(0)?, r.try_get(1)?, r.try_get(2)?);
        if !input.is_empty() {
            input.push_str("\n\n");
        }
        input.push_str(match (kind, body) {
            ("continue", None) => stopped,
            ("timer", None) => TIMER,
            (_, b) => b.unwrap_or_default(),
        });
        upto = upto.max(id);
    }
    Ok(Some(Turn {
        session_uuid,
        input,
        upto,
        first,
        checkpoint,
        transcript,
    }))
}

/// Marks the inbox rows the turn of `attempt` at `epoch` was handed read, unless its input never reached the agent.
fn mark_read(
    tx: &mut Transaction<'_>,
    (task, attempt, epoch): (&str, &str, i64),
    park: &Park,
) -> Result<(), QueueError> {
    if park.undelivered {
        return Ok(());
    }
    tx.execute(
        // what the claim handed over: up to upto, and due when it leased (its event's `at` is the claim's now())
        "UPDATE inbox SET consumed_epoch = $3 WHERE task_id = $1 AND id <= $2 AND consumed_epoch IS NULL \
         AND (due_at IS NULL OR due_at <= (SELECT max(e.at) FROM events e \
         WHERE e.attempt_id = $4 AND e.lease_epoch = $3 AND e.to_status = 'leased'))",
        &[&task, &park.upto, &epoch, &attempt],
    )?;
    Ok(())
}

/// Replaces `task`'s transcript with `t`, the one its turn at `epoch` left; `None` keeps the one it has.
fn put_transcript(
    tx: &mut Transaction<'_>,
    task: &str,
    epoch: i64,
    t: Option<&Transcript>,
) -> Result<(), QueueError> {
    let Some(t) = t else {
        return Ok(());
    };
    if t.body.len() > TRANSCRIPT_BYTES {
        return Err(QueueError::Range("transcript"));
    }
    if !Transcript::valid_project(&t.project) {
        return Err(QueueError::Range("transcript project"));
    }
    tx.execute(
        "INSERT INTO transcripts (task_id, lease_epoch, project, body) VALUES ($1, $2, $3, $4) \
         ON CONFLICT (task_id) DO UPDATE SET lease_epoch = EXCLUDED.lease_epoch, project = EXCLUDED.project, \
         body = EXCLUDED.body, updated_at = now() WHERE transcripts.lease_epoch <= EXCLUDED.lease_epoch",
        &[&task, &epoch, &t.project, &t.body],
    )?;
    Ok(())
}

/// Upper bounds of the duration histograms, in seconds: ten seconds to four hours.
const BUCKETS: [u32; 8] = [10, 60, 300, 900, 1800, 3600, 7200, 14400];

/// State changes by host, from, to and reason.
fn transitions(tx: &mut Transaction<'_>, out: &mut String) -> Result<(), QueueError> {
    out.push_str(
        "# HELP exec_pool_transitions_total State changes by host, from, to and reason.\n\
         # TYPE exec_pool_transitions_total counter\n",
    );
    for r in tx.query(
        &format!(
            "SELECT coalesce({EPOCH_HOST}, 'none'), coalesce(e.from_status, 'none'), e.to_status, e.reason, \
             count(*) FROM events e GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4"
        ),
        &[],
    )? {
        let (host, from, to, why, n): (&str, &str, &str, &str, i64) = (
            r.try_get(0)?,
            r.try_get(1)?,
            r.try_get(2)?,
            r.try_get(3)?,
            r.try_get(4)?,
        );
        let _ = writeln!(
            out,
            "exec_pool_transitions_total{{host=\"{host}\",from=\"{from}\",to=\"{to}\",reason=\"{why}\"}} {n}"
        );
    }
    Ok(())
}

/// Every host a runner has claimed for: each per-host series is present for these at zero with nothing there.
fn slot_hosts(tx: &mut Transaction<'_>) -> Result<Vec<String>, QueueError> {
    tx.query("SELECT DISTINCT host FROM slots ORDER BY 1", &[])?
        .iter()
        .map(|r| r.try_get(0).map_err(Into::into))
        .collect()
}

/// `hosts` and `none`, for a series whose rows may carry no host.
fn with_none(hosts: &[String]) -> Vec<String> {
    let mut all = hosts.to_vec();
    all.push("none".to_owned());
    all
}

/// The host an attempt under `a` holds, or else the one its last lease ran on: a park or a settle takes it off its slot.
const LAST_HOST: &str = "coalesce(a.host, (SELECT h.host FROM events h WHERE h.attempt_id = a.id \
    AND h.host IS NOT NULL ORDER BY h.id DESC LIMIT 1))";
/// The host of an event under `e`, or else the one its lease ran on at that epoch: a park leaves the slot.
const EPOCH_HOST: &str = "coalesce(e.host, (SELECT h.host FROM events h WHERE h.attempt_id = e.attempt_id \
    AND h.lease_epoch = e.lease_epoch AND h.host IS NOT NULL ORDER BY h.id DESC LIMIT 1))";

/// Slots whose runner claimed in the last two minutes (an idle one polls every ten seconds) and that hold no live
/// lease and no quarantine: free for a queued attempt they offer the agent of.
const IDLE_SLOTS: &str = "SELECT s.host, s.agents FROM slots s WHERE s.seen_at > now() - interval '2 minutes' \
    AND NOT EXISTS (SELECT FROM attempts l WHERE l.host = s.host AND l.slot = s.id \
    AND l.status IN ('leased', 'running', 'checkpointing')) \
    AND NOT EXISTS (SELECT FROM quarantined_slots q WHERE q.host = s.host AND q.slot = s.id)";

/// A histogram, per host and agent kind, each of `hosts` and kinds present at zero, of the time attempts spent in
/// `from` before moving to `to`. `head` is its HELP and TYPE lines, literal so the dashboard check finds the name.
fn histogram(
    tx: &mut Transaction<'_>,
    out: &mut String,
    name: &str,
    head: &str,
    (from, to): (&str, &str),
    hosts: &[String],
) -> Result<(), QueueError> {
    distribution(
        tx,
        out,
        (name, head),
        ("agent", &AGENTS),
        &BUCKETS.map(u64::from),
        &format!(
            "SELECT {EPOCH_HOST}, t.spec->'command'->>'agent', e.in_state_ms / 1000.0 FROM events e \
             JOIN tasks t ON t.id = e.task_id WHERE e.from_status = '{from}' AND e.to_status = '{to}'"
        ),
        hosts,
    )
}

/// Waiting attempts by host and the reason they last went there: each park reason, at zero with none, and any other.
fn waiting(tx: &mut Transaction<'_>, out: &mut String, hosts: &[String]) -> Result<(), QueueError> {
    out.push_str(
        "# HELP exec_pool_waiting Waiting attempts by host and why they wait: a session's park reason, or settle.\n\
         # TYPE exec_pool_waiting gauge\n",
    );
    for (host, why, n) in counted(
        tx,
        &format!(
            "SELECT {LAST_HOST}, coalesce((SELECT e.reason FROM events e WHERE e.attempt_id = a.id \
             AND e.to_status = 'waiting' ORDER BY e.id DESC LIMIT 1), 'none'), count(*) FROM attempts a \
             WHERE a.status = 'waiting' GROUP BY 1, 2"
        ),
        hosts,
        &ParkReason::ALL.map(ParkReason::as_str),
    )? {
        let _ = writeln!(
            out,
            "exec_pool_waiting{{host=\"{host}\",reason=\"{why}\"}} {n}"
        );
    }
    Ok(())
}

/// Counts by host and a bounded code, from `sql`'s (host, code, count) rows, a null host as `none`: each of `hosts`
/// with each of `known` (at zero with none), then any other pair the query returns.
fn counted(
    tx: &mut Transaction<'_>,
    sql: &str,
    hosts: &[String],
    known: &[&str],
) -> Result<Vec<(String, String, i64)>, QueueError> {
    let mut out: Vec<(String, String, i64)> = hosts
        .iter()
        .flat_map(|h| known.iter().map(move |k| (h.clone(), (*k).to_owned(), 0)))
        .collect();
    for r in tx.query(sql, &[])? {
        let (host, code, n): (Option<String>, String, i64) =
            (r.try_get(0)?, r.try_get(1)?, r.try_get(2)?);
        let host = host.unwrap_or_else(|| "none".to_owned());
        match out.iter_mut().find(|(h, k, _)| *h == host && *k == code) {
            Some(slot) => slot.2 = n,
            None => out.push((host, code, n)),
        }
    }
    Ok(out)
}

/// A histogram, per host and value of `label` (each of `hosts` with each of `values` present at zero, and any other
/// host the rows name), of the values `sql` returns as (host text, label text, value float8), against `buckets`.
/// `head` is its HELP and TYPE lines, literal so the dashboard check finds the name.
fn distribution(
    tx: &mut Transaction<'_>,
    out: &mut String,
    (name, head): (&str, &str),
    (label, values): (&str, &[&str]),
    buckets: &[u64],
    sql: &str,
    hosts: &[String],
) -> Result<(), QueueError> {
    let filters: Vec<String> = buckets
        .iter()
        .map(|b| format!("count(*) FILTER (WHERE x.v <= {b})"))
        .collect();
    let rows = tx.query(
        &format!(
            "SELECT coalesce(x.h, 'none'), x.l, count(*), coalesce(sum(x.v), 0)::float8, ARRAY[{}] \
             FROM ({sql}) x (h, l, v) GROUP BY 1, 2",
            filters.join(", ")
        ),
        &[],
    )?;
    let mut all = hosts.to_vec();
    for r in &rows {
        let h: String = r.try_get(0)?;
        if !all.contains(&h) {
            all.push(h);
        }
    }
    out.push_str(head);
    for host in &all {
        for value in values {
            let row = rows.iter().find(|r| {
                r.try_get::<_, &str>(0).ok() == Some(host.as_str())
                    && r.try_get::<_, Option<&str>>(1).ok().flatten() == Some(*value)
            });
            let (count, sum, counts): (i64, f64, Vec<i64>) = match row {
                Some(r) => (r.try_get(2)?, r.try_get(3)?, r.try_get(4)?),
                None => (0, 0.0, vec![0; buckets.len()]),
            };
            let at = format!("host=\"{host}\",{label}=\"{value}\"");
            for (b, n) in buckets.iter().zip(counts) {
                let _ = writeln!(out, "{name}_bucket{{{at},le=\"{b}\"}} {n}");
            }
            let _ = write!(
                out,
                "{name}_bucket{{{at},le=\"+Inf\"}} {count}\n\
                 {name}_sum{{{at}}} {sum}\n{name}_count{{{at}}} {count}\n"
            );
        }
    }
    Ok(())
}

/// Turns per closed session.
const TURN_COUNTS: [u64; 7] = [1, 2, 5, 10, 20, 50, 100];
/// A closed session's age: an hour to thirty days.
const AGES: [u64; 7] = [3600, 21600, 86400, 259_200, 604_800, 1_209_600, 2_592_000];
/// How long a waiting session has sat unchanged: one, three, seven and fourteen days.
const IDLE: [u64; 4] = [86400, 259_200, 604_800, 1_209_600];
/// What an inbox row is, as a wake's source.
const SOURCES: [&str; 3] = ["message", "timer", "continue"];
/// A session's turn: started, then parked to waiting for one of the park reasons (not a settle).
const PARKED: &str = "e.to_status = 'waiting' AND e.from_status IN ('running', 'checkpointing') \
    AND e.reason IN ('turn_end', 'waiting_until', 'preempted', 'host_draining', 'turn_error', 'turn_timeout')";

/// The sessions' series: by state, turns by park reason and their durations, wake latency by source, closed sessions'
/// turns and age, how long parked ones sit idle, host changes between turns and the tokens and cost turns report. A
/// session's host is the one its attempt last ran on.
fn sessions(
    tx: &mut Transaction<'_>,
    out: &mut String,
    hosts: &[String],
) -> Result<(), QueueError> {
    out.push_str(
        "# HELP exec_pool_sessions Sessions by host and state: running is leased, running or checkpointing; closed is final.\n\
         # TYPE exec_pool_sessions gauge\n",
    );
    for (host, state, n) in counted(
        tx,
        &format!(
            "SELECT {LAST_HOST}, CASE WHEN a.status IN ('leased', 'running', 'checkpointing') THEN 'running' \
             WHEN a.status IN ('succeeded', 'failed', 'cancelled') THEN 'closed' ELSE a.status END, count(*) \
             FROM attempts a JOIN tasks t ON t.id = a.task_id WHERE t.session GROUP BY 1, 2"
        ),
        hosts,
        &["running", "queued", "waiting", "needs_review", "closed"],
    )? {
        let _ = writeln!(
            out,
            "exec_pool_sessions{{host=\"{host}\",state=\"{state}\"}} {n}"
        );
    }
    let reasons = ParkReason::ALL.map(ParkReason::as_str);
    out.push_str(
        "# HELP exec_pool_sessions_waiting Waiting sessions by host and the reason their last turn parked.\n\
         # TYPE exec_pool_sessions_waiting gauge\n",
    );
    for (host, why, n) in counted(
        tx,
        &format!(
            "SELECT {LAST_HOST}, coalesce((SELECT e.reason FROM events e WHERE e.attempt_id = a.id \
             AND e.to_status = 'waiting' ORDER BY e.id DESC LIMIT 1), 'none'), count(*) FROM attempts a \
             JOIN tasks t ON t.id = a.task_id WHERE t.session AND a.status = 'waiting' GROUP BY 1, 2"
        ),
        hosts,
        &reasons,
    )? {
        let _ = writeln!(
            out,
            "exec_pool_sessions_waiting{{host=\"{host}\",reason=\"{why}\"}} {n}"
        );
    }
    out.push_str(
        "# HELP exec_pool_session_turns_total Session turns parked, by host and park reason.\n\
         # TYPE exec_pool_session_turns_total counter\n",
    );
    for (host, why, n) in counted(
        tx,
        &format!(
            "SELECT {EPOCH_HOST}, e.reason, count(*) FROM events e JOIN tasks t ON t.id = e.task_id \
             WHERE t.session AND {PARKED} GROUP BY 1, 2"
        ),
        hosts,
        &reasons,
    )? {
        let _ = writeln!(
            out,
            "exec_pool_session_turns_total{{host=\"{host}\",reason=\"{why}\"}} {n}"
        );
    }
    session_durations(tx, out, hosts)?;
    session_totals(tx, out, hosts)
}

/// Turn time, wake latency, closed sessions' turns and age, and how long parked ones sit idle.
fn session_durations(
    tx: &mut Transaction<'_>,
    out: &mut String,
    hosts: &[String],
) -> Result<(), QueueError> {
    distribution(
        tx,
        out,
        (
            "exec_pool_session_turn_seconds",
            "# HELP exec_pool_session_turn_seconds A session turn's time from start to park, by host and agent kind.\n\
             # TYPE exec_pool_session_turn_seconds histogram\n",
        ),
        ("agent", &AGENTS),
        &BUCKETS.map(u64::from),
        &format!(
            "SELECT s.host, t.spec->'command'->>'agent', extract(epoch FROM e.at - s.at)::float8 FROM events e \
             JOIN events s ON s.attempt_id = e.attempt_id AND s.lease_epoch = e.lease_epoch AND s.to_status = 'running' \
             JOIN tasks t ON t.id = e.task_id WHERE t.session AND {PARKED}"
        ),
        hosts,
    )?;
    distribution(
        tx,
        out,
        (
            "exec_pool_session_wake_seconds",
            "# HELP exec_pool_session_wake_seconds From an inbox row due (sent, or a timer's due_at) to the start of the turn it was handed to, by host and source.\n\
             # TYPE exec_pool_session_wake_seconds histogram\n",
        ),
        ("source", &SOURCES),
        &BUCKETS.map(u64::from),
        "SELECT s.host, i.kind, extract(epoch FROM s.at - greatest(i.created_at, coalesce(i.due_at, i.created_at)))::float8 \
         FROM inbox i JOIN attempts a ON a.task_id = i.task_id JOIN events s ON s.attempt_id = a.id \
         AND s.lease_epoch = i.consumed_epoch AND s.to_status = 'running'",
        hosts,
    )?;
    let closed = "FROM attempts a JOIN tasks t ON t.id = a.task_id \
         WHERE t.session AND a.status IN ('succeeded', 'failed', 'cancelled')";
    distribution(
        tx,
        out,
        (
            "exec_pool_session_turns",
            "# HELP exec_pool_session_turns Turns started per closed session, by host and agent kind.\n\
             # TYPE exec_pool_session_turns histogram\n",
        ),
        ("agent", &AGENTS),
        &TURN_COUNTS,
        &format!(
            "SELECT {LAST_HOST}, t.spec->'command'->>'agent', (SELECT count(*) FROM events e \
             WHERE e.attempt_id = a.id AND e.to_status = 'running')::float8 {closed}"
        ),
        hosts,
    )?;
    distribution(
        tx,
        out,
        (
            "exec_pool_session_age_seconds",
            "# HELP exec_pool_session_age_seconds A closed session's time from start to its final state, by host and agent kind.\n\
             # TYPE exec_pool_session_age_seconds histogram\n",
        ),
        ("agent", &AGENTS),
        &AGES,
        &format!(
            "SELECT {LAST_HOST}, t.spec->'command'->>'agent', extract(epoch FROM a.changed_at - t.submitted_at)::float8 {closed}"
        ),
        hosts,
    )?;
    let waiting =
        "FROM attempts a JOIN tasks t ON t.id = a.task_id WHERE t.session AND a.status = 'waiting'";
    distribution(
        tx,
        out,
        (
            "exec_pool_sessions_parked_seconds",
            "# HELP exec_pool_sessions_parked_seconds Waiting sessions by how long they have sat unchanged, by host and agent kind.\n\
             # TYPE exec_pool_sessions_parked_seconds histogram\n",
        ),
        ("agent", &AGENTS),
        &IDLE,
        &format!(
            "SELECT {LAST_HOST}, t.spec->'command'->>'agent', extract(epoch FROM now() - a.changed_at)::float8 {waiting}"
        ),
        hosts,
    )?;
    Ok(())
}

/// The oldest parked session, host changes and the usage turns reported, by the host the turn ran on.
fn session_totals(
    tx: &mut Transaction<'_>,
    out: &mut String,
    hosts: &[String],
) -> Result<(), QueueError> {
    let waiting =
        "FROM attempts a JOIN tasks t ON t.id = a.task_id WHERE t.session AND a.status = 'waiting'";
    let oldest: f64 = tx
        .query_one(
            &format!(
                "SELECT coalesce(max(extract(epoch FROM now() - a.changed_at)), 0)::float8 {waiting}"
            ),
            &[],
        )?
        .try_get(0)?;
    let _ = write!(
        out,
        "# HELP exec_pool_sessions_parked_oldest_seconds How long the longest-unchanged waiting session has sat (0 with none).\n\
         # TYPE exec_pool_sessions_parked_oldest_seconds gauge\nexec_pool_sessions_parked_oldest_seconds {oldest}\n\
         # HELP exec_pool_session_host_changes_total Session turns started on another host than the turn before, by the host it started on.\n\
         # TYPE exec_pool_session_host_changes_total counter\n"
    );
    for (host, _, n) in counted(
        tx,
        "SELECT l.host, '', count(*) FROM (SELECT e.host, lag(e.host) OVER (PARTITION BY e.attempt_id ORDER BY e.id) \
         FROM events e JOIN tasks t ON t.id = e.task_id WHERE t.session AND e.to_status = 'running') l (host, prev) \
         WHERE l.prev IS NOT NULL AND l.host IS DISTINCT FROM l.prev GROUP BY 1",
        hosts,
        &[""],
    )? {
        let _ = writeln!(
            out,
            "exec_pool_session_host_changes_total{{host=\"{host}\"}} {n}"
        );
    }
    usage(tx, out, hosts)
}

/// The tokens and cost session turns reported, by the host each turn ran on and agent kind.
fn usage(tx: &mut Transaction<'_>, out: &mut String, hosts: &[String]) -> Result<(), QueueError> {
    // a turn's host is where its lease ran: the running event at the turn's epoch
    let rows = tx.query(
        "SELECT coalesce((SELECT e.host FROM events e WHERE e.attempt_id = u.attempt_id \
         AND e.lease_epoch = u.lease_epoch AND e.to_status = 'running' ORDER BY e.id DESC LIMIT 1), 'none'), \
         t.spec->'command'->>'agent', count(u.input_tokens), coalesce(sum(u.input_tokens), 0)::bigint, \
         coalesce(sum(u.output_tokens), 0)::bigint, coalesce(sum(u.cache_read_tokens), 0)::bigint, \
         coalesce(sum(u.cache_creation_tokens), 0)::bigint, coalesce(sum(u.cost_usd), 0)::float8 \
         FROM turns u JOIN attempts a ON a.id = u.attempt_id JOIN tasks t ON t.id = a.task_id GROUP BY 1, 2",
        &[],
    )?;
    let mut all = hosts.to_vec();
    for r in &rows {
        let h: String = r.try_get(0)?;
        if !all.contains(&h) {
            all.push(h);
        }
    }
    let heads = [
        "# HELP exec_pool_session_turns_reported_total Session turns that reported their usage, by host and agent kind.\n\
         # TYPE exec_pool_session_turns_reported_total counter\n",
        "# HELP exec_pool_session_input_tokens_total Uncached input tokens session turns reported, by host and agent kind.\n\
         # TYPE exec_pool_session_input_tokens_total counter\n",
        "# HELP exec_pool_session_output_tokens_total Output tokens session turns reported, by host and agent kind.\n\
         # TYPE exec_pool_session_output_tokens_total counter\n",
        "# HELP exec_pool_session_cache_read_tokens_total Input tokens read from the prompt cache, by host and agent kind.\n\
         # TYPE exec_pool_session_cache_read_tokens_total counter\n",
        "# HELP exec_pool_session_cache_creation_tokens_total Input tokens written to the prompt cache, by host and agent kind.\n\
         # TYPE exec_pool_session_cache_creation_tokens_total counter\n",
    ];
    let row_of = |host: &str, agent: &str| {
        rows.iter().find(|r| {
            r.try_get::<_, &str>(0).ok() == Some(host)
                && r.try_get::<_, Option<&str>>(1).ok().flatten() == Some(agent)
        })
    };
    for (i, head) in heads.iter().enumerate() {
        out.push_str(head);
        let name = head.split_whitespace().nth(2).unwrap_or_default();
        for host in &all {
            for agent in AGENTS {
                let n: i64 = row_of(host, agent)
                    .map(|r| r.try_get(i.saturating_add(2)))
                    .transpose()?
                    .unwrap_or(0);
                let _ = writeln!(out, "{name}{{host=\"{host}\",agent=\"{agent}\"}} {n}");
            }
        }
    }
    out.push_str(
        "# HELP exec_pool_session_cost_usd_total The cost session turns reported, in US dollars, by host and agent kind.\n\
         # TYPE exec_pool_session_cost_usd_total counter\n",
    );
    for host in &all {
        for agent in AGENTS {
            let cost: f64 = row_of(host, agent)
                .map(|r| r.try_get(7))
                .transpose()?
                .unwrap_or(0.0);
            let _ = writeln!(
                out,
                "exec_pool_session_cost_usd_total{{host=\"{host}\",agent=\"{agent}\"}} {cost}"
            );
        }
    }
    Ok(())
}

/// Live leases past their deadline by host and state, and each host's slots: those its runners claimed for in the
/// last week, and by state.
fn leases(tx: &mut Transaction<'_>, out: &mut String, hosts: &[String]) -> Result<(), QueueError> {
    out.push_str(
        "# HELP exec_pool_lease_overdue Live attempts past their lease deadline that no reconcile has expired, by host and state.\n\
         # TYPE exec_pool_lease_overdue gauge\n",
    );
    for (host, state, n) in counted(
        tx,
        &format!(
            "SELECT host, status, count(*) FROM attempts \
             WHERE status IN {LIVE} AND lease_deadline <= now() GROUP BY 1, 2"
        ),
        hosts,
        &["leased", "running", "checkpointing"],
    )? {
        let _ = writeln!(
            out,
            "exec_pool_lease_overdue{{host=\"{host}\",state=\"{state}\"}} {n}"
        );
    }
    // one live attempt per slot (attempts_slot_live), so live attempts are busy slots
    out.push_str(
        "# HELP exec_pool_slots Slots by host and state: busy holds a live lease, quarantined failed its reset, idle polls for work.\n\
         # TYPE exec_pool_slots gauge\n",
    );
    for (host, state, n) in counted(
        tx,
        &format!(
            "SELECT host, 'busy', count(*) FROM attempts WHERE status IN {LIVE} GROUP BY 1 \
             UNION ALL SELECT host, 'quarantined', count(*) FROM quarantined_slots GROUP BY 1 \
             UNION ALL SELECT host, 'idle', count(*) FROM ({IDLE_SLOTS}) s GROUP BY 1"
        ),
        hosts,
        &["busy", "quarantined", "idle"],
    )? {
        let _ = writeln!(
            out,
            "exec_pool_slots{{host=\"{host}\",state=\"{state}\"}} {n}"
        );
    }
    out.push_str(
        "# HELP exec_pool_slots_declared Slots each host's runners claimed for in the last week.\n\
         # TYPE exec_pool_slots_declared gauge\n",
    );
    for (host, _, n) in counted(
        tx,
        "SELECT host, '', count(*) FROM slots WHERE seen_at > now() - interval '7 days' GROUP BY 1",
        hosts,
        &[""],
    )? {
        let _ = writeln!(out, "exec_pool_slots_declared{{host=\"{host}\"}} {n}");
    }
    Ok(())
}
