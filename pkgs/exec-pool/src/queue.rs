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
use serde::Serialize;
use serde_json::Value;

use crate::task_result::TaskResult;
use crate::{
    Attempt, Error, Event, Kind, Placement, Receipt, Resolution, RetryPolicy, SchemaVersion,
    Settle, Slot, Status, TaskSpec, transition,
};

pub const UP: &str = include_str!("../migrations/0001_queue.up.sql");
pub const DOWN: &str = include_str!("../migrations/0001_queue.down.sql");
/// Migration `n` is `STEPS[n - 1]`; each records its own version.
const STEPS: [&str; 3] = [
    UP,
    include_str!("../migrations/0002_submitter.up.sql"),
    include_str!("../migrations/0003_result.up.sql"),
];
const DOWN_SUBMITTER: &str = include_str!("../migrations/0002_submitter.down.sql");
const DOWN_RESULT: &str = include_str!("../migrations/0003_result.down.sql");
const VERSION: i32 = 3;
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

const STATUSES: [Status; 8] = [
    Status::Queued,
    Status::Leased,
    Status::Running,
    Status::Checkpointing,
    Status::Waiting,
    Status::Succeeded,
    Status::Failed,
    Status::NeedsReview,
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
    #[error("the database is at migration {0}, newer than this binary's {VERSION}")]
    SchemaAhead(i32),
    #[error("the database is not migrated")]
    NotMigrated,
    #[error("no attempt {0}")]
    NotFound(String),
    #[error("attempt {0} holds no live lease")]
    NotLive(String),
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
        (_, Status::Failed) => "attempts_exhausted",
        (Kind::Lease(_), _) => "lease",
        (Kind::Start, _) => "start",
        (Kind::Checkpoint, _) => "checkpoint",
        (Kind::Settle(_), _) => "settle",
        (Kind::Wake, _) => "wake",
        (Kind::Expire, _) => "lease_expired",
        (Kind::Resolve(_), _) => "operator",
    }
}

/// The columns an attempt row is read with, under `a` (attempts) and `t` (tasks).
const ATTEMPT_COLS: &str = "a.id, a.task_id, a.lease_epoch, a.tries, a.status, a.host, a.slot, a.pins, \
    t.max_attempts, (a.lease_deadline <= clock_timestamp()) AS expired, \
    (extract(epoch FROM now() - a.changed_at) * 1000)::bigint AS in_state_ms, \
    (extract(epoch FROM now() - t.submitted_at) * 1000)::bigint AS since_submit_ms";

/// One task and its attempt as `status` and `list` show them, under `a` (attempts) and `t` (`task_summaries`).
const SUMMARY: &str = "jsonb_build_object('task', t.id, 'attempt', a.id, 'status', a.status, \
    'agent', t.agent, 'repo', t.repo, 'rev', t.rev, \
    'workdir', t.workdir, 'lease_epoch', a.lease_epoch, 'tries', a.tries, 'host', a.host, \
    'slot', a.slot, 'submitted_at', t.submitted_at, 'changed_at', a.changed_at)";

struct Locked {
    attempt: Attempt,
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
    lease_secs: u32,
) -> Result<(Attempt, Change), QueueError> {
    let next = transition(&row.attempt, &row.retry, event)?;
    // the settle the holder asked for: a retry that exhaustion turns into a failure has no receipt
    let terminal = matches!(
        event.kind,
        Kind::Settle(Settle::Succeeded | Settle::Failed | Settle::NeedsReview)
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
    let checkpoint = receipt
        .and_then(|r| r.checkpoint.as_ref())
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

    /// Applies the migrations the database lacks; refuses a database a newer binary migrated.
    ///
    /// # Errors
    /// [`QueueError::SchemaAhead`], or what the database reports.
    pub fn migrate(&mut self) -> Result<(), QueueError> {
        self.tx(|tx| {
            // two first migrations at once would both see no schema
            tx.execute("SELECT pg_advisory_xact_lock(651)", &[])?;
            let done = Self::version(tx)?.unwrap_or(0);
            if done > VERSION {
                return Err(QueueError::SchemaAhead(done));
            }
            let done = usize::try_from(done).map_err(|_| QueueError::Range("schema version"))?;
            STEPS
                .iter()
                .skip(done)
                .try_for_each(|step| Ok(tx.batch_execute(step)?))
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
            Some(_) => Ok(tx.batch_execute(&format!("{DOWN_RESULT}{DOWN_SUBMITTER}{DOWN}"))?),
        })
    }

    /// Queues `task` through `submit_task`, as `exec_pool_submit` may: the queue assigns its id from its key and refuses
    /// any task but the shape `exec-pool submit` builds. The queued task's id and whether it was already queued.
    ///
    /// # Errors
    /// What `submit_task` or the database reports, an idempotency conflict included.
    pub fn submit_task(&mut self, task: &TaskSpec) -> Result<(String, bool), QueueError> {
        let mut spec = serde_json::to_value(task)?;
        if let Value::Object(m) = &mut spec {
            m.remove("id");
        }
        self.tx(|tx| {
            let row = tx.query_one("SELECT o_task, o_duplicate FROM submit_task($1)", &[&spec])?;
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

    /// Leases the oldest queued attempt that fits `slot` for `lease_secs`, skipping rows another claimer holds.
    ///
    /// # Errors
    /// What [`Slot::validate`] rejects, or what the database reports (a slot with a live lease already included).
    pub fn claim(&mut self, slot: &Slot, lease_secs: u32) -> Result<Option<Claim>, QueueError> {
        slot.validate()?;
        if lease_secs == 0 {
            return Err(QueueError::Range("lease_secs"));
        }
        self.tx(|tx| {
            // read every queued task unlocked, then lock only the one taken, so a claimer holds no row it skips
            let candidates = tx.query(
                "SELECT a.id, t.spec FROM attempts a JOIN tasks t ON t.id = a.task_id \
                 WHERE a.status = 'queued' ORDER BY a.changed_at, a.id",
                &[],
            )?;
            for candidate in &candidates {
                let task: TaskSpec = serde_json::from_value(candidate.try_get(1)?)?;
                if task.fits(slot).is_err() {
                    continue;
                }
                let id: &str = candidate.try_get(0)?;
                let rows = tx.query(
                    &format!(
                        "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id \
                         WHERE a.id = $1 AND a.status = 'queued' FOR UPDATE OF a SKIP LOCKED"
                    ),
                    &[&id],
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
                let (attempt, change) = write(tx, row, &event, None, lease_secs)?;
                return Ok(Some(Claim {
                    task,
                    attempt,
                    change,
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
    /// [`Store::claim`]'s and an expiry [`Store::reconcile`]'s. A holder's event after its lease deadline is refused:
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
            if matches!(event.kind, Kind::Lease(_) | Kind::Expire) {
                return Err(Error::IllegalTransition {
                    from: row.attempt.status,
                    event: "lease or expire outside claim and reconcile",
                }
                .into());
            }
            let holder = matches!(event.kind, Kind::Start | Kind::Checkpoint | Kind::Settle(_));
            if holder && row.expired && event.epoch == row.attempt.lease_epoch {
                return Err(QueueError::NotLive(attempt.to_owned()));
            }
            write(tx, row, event, receipt, 0)
        })
    }

    /// Extends a live lease to `lease_secs` from now.
    ///
    /// # Errors
    /// [`QueueError::NotLive`] when the attempt has no unexpired lease, [`QueueError::Fenced`] at a stale epoch.
    pub fn heartbeat(
        &mut self,
        attempt: &str,
        epoch: u64,
        lease_secs: u32,
    ) -> Result<(), QueueError> {
        if lease_secs == 0 {
            return Err(QueueError::Range("lease_secs"));
        }
        self.tx(|tx| {
            let n = tx.execute(
                &format!(
                    "UPDATE attempts SET lease_deadline = now() + make_interval(secs => $3), fence = $2 \
                     WHERE id = $1 AND status IN {LIVE} AND lease_deadline > clock_timestamp()"
                ),
                &[&attempt, &i64_of("epoch", epoch)?, &f64::from(lease_secs)],
            )?;
            if n == 1 {
                Ok(())
            } else {
                Err(QueueError::NotLive(attempt.to_owned()))
            }
        })
    }

    /// Expires every lease past its deadline: a lease that never started goes back to queued (or fails with no
    /// attempt left), a started one to `needs_review`. Run at startup and on a timer.
    ///
    /// # Errors
    /// What the database reports.
    pub fn reconcile(&mut self) -> Result<Vec<Change>, QueueError> {
        self.tx(|tx| {
            let rows = tx.query(
                &format!(
                    "SELECT {ATTEMPT_COLS} FROM attempts a JOIN tasks t ON t.id = a.task_id \
                     WHERE a.status IN {LIVE} AND a.lease_deadline <= now() FOR UPDATE OF a SKIP LOCKED"
                ),
                &[],
            )?;
            rows.iter()
                .map(|row| {
                    let row = locked(row)?;
                    let event = Event {
                        epoch: row.attempt.lease_epoch,
                        kind: Kind::Expire,
                    };
                    write(tx, row, &event, None, 0).map(|(_, c)| c)
                })
                .collect()
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
        let outcome = result
            .outcome
            .map(serde_json::to_value)
            .transpose()?
            .and_then(|v| v.as_str().map(str::to_owned));
        self.tx(|tx| {
            let epoch = i64_of("epoch", epoch)?;
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
                "INSERT INTO results (attempt_id, lease_epoch, outcome, exit_code, output) VALUES ($1, $2, $3, $4, $5) \
                 ON CONFLICT (attempt_id) DO UPDATE SET lease_epoch = EXCLUDED.lease_epoch, outcome = EXCLUDED.outcome, \
                 exit_code = EXCLUDED.exit_code, output = EXCLUDED.output, recorded_at = now() \
                 WHERE results.lease_epoch < EXCLUDED.lease_epoch",
                &[&attempt, &epoch, &outcome, &result.exit_code, &result.output],
            )?;
            Ok(n == 1)
        })
    }

    /// The task `id` names, as [`Store::tasks`] shows it, with its attempt's recorded `result` (`null` before one);
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
                     'exit_code', r.exit_code, 'output', r.output, 'recorded_at', r.recorded_at) END) \
                     FROM task_summaries t JOIN attempts a ON a.task_id = t.id \
                     LEFT JOIN results r ON r.attempt_id = a.id WHERE t.id = $1 OR a.id = $1"
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

    /// The queue's counters in the Prometheus text format, for a textfile collector. Labels are states, agent kinds
    /// and reason codes only. `declared_slots` is the host's configured slot count, when the caller knows it. When it
    /// fails for any reason, render [`METRICS_UNAVAILABLE`] instead.
    ///
    /// # Errors
    /// What the database reports.
    pub fn metrics(&mut self, declared_slots: Option<u32>) -> Result<String, QueueError> {
        self.tx(|tx| {
            // one snapshot, so busy slots, counts and histograms agree within a scrape
            tx.batch_execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")?;
            let mut out = String::from(
                concat!(
                    up_help!(),
                    "exec_pool_queue_up 1\n\
                     # HELP exec_pool_attempts Attempts by state and agent kind (one per task).\n\
                     # TYPE exec_pool_attempts gauge\n",
                ),
            );
            let counts = tx.query(
                "SELECT a.status, t.spec->'command'->>'agent', count(*) FROM attempts a \
                 JOIN tasks t ON t.id = a.task_id GROUP BY 1, 2",
                &[],
            )?;
            for s in STATUSES {
                let state = status_str(s);
                for agent in AGENTS {
                    let mut n = 0_i64;
                    for r in &counts {
                        if r.try_get::<_, &str>(0)? == state
                            && r.try_get::<_, Option<&str>>(1)? == Some(agent)
                        {
                            n = r.try_get(2)?;
                        }
                    }
                    let _ = writeln!(
                        out,
                        "exec_pool_attempts{{state=\"{state}\",agent=\"{agent}\"}} {n}"
                    );
                }
            }
            let oldest: f64 = tx
                .query_one(
                    "SELECT coalesce(extract(epoch FROM now() - min(changed_at)), 0)::float8 \
                     FROM attempts WHERE status = 'queued'",
                    &[],
                )?
                .try_get(0)?;
            let _ = write!(
                out,
                "# HELP exec_pool_queued_oldest_seconds Age of the oldest queued attempt (0 with none).\n\
                 # TYPE exec_pool_queued_oldest_seconds gauge\nexec_pool_queued_oldest_seconds {oldest}\n"
            );
            leases(tx, &mut out, declared_slots)?;
            histogram(
                tx,
                &mut out,
                "exec_pool_queue_wait_seconds",
                "# HELP exec_pool_queue_wait_seconds Time from queued to leased, by agent kind.\n\
                 # TYPE exec_pool_queue_wait_seconds histogram\n",
                ("queued", "leased"),
            )?;
            histogram(
                tx,
                &mut out,
                "exec_pool_run_seconds",
                "# HELP exec_pool_run_seconds Time running until a checkpoint, by agent kind; an expiry is not a run.\n\
                 # TYPE exec_pool_run_seconds histogram\n",
                ("running", "checkpointing"),
            )?;
            out.push_str(
                "# HELP exec_pool_transitions_total State changes by from, to and reason.\n\
                 # TYPE exec_pool_transitions_total counter\n",
            );
            for r in tx.query(
                "SELECT coalesce(from_status, 'none'), to_status, reason, count(*) FROM events \
                 GROUP BY 1, 2, 3 ORDER BY 1, 2, 3",
                &[],
            )? {
                let (from, to, why, n): (&str, &str, &str, i64) =
                    (r.try_get(0)?, r.try_get(1)?, r.try_get(2)?, r.try_get(3)?);
                let _ = writeln!(
                    out,
                    "exec_pool_transitions_total{{from=\"{from}\",to=\"{to}\",reason=\"{why}\"}} {n}"
                );
            }
            Ok(out)
        })
    }
}

/// Upper bounds of the duration histograms, in seconds: ten seconds to four hours.
const BUCKETS: [u32; 8] = [10, 60, 300, 900, 1800, 3600, 7200, 14400];

/// A histogram, per agent kind and every kind present at zero, of the time attempts spent in `from` before moving to `to`.
/// `head` is its HELP and TYPE lines, literal so the dashboard check finds the name.
fn histogram(
    tx: &mut Transaction<'_>,
    out: &mut String,
    name: &str,
    head: &str,
    (from, to): (&str, &str),
) -> Result<(), QueueError> {
    let filters: Vec<String> = BUCKETS
        .iter()
        .map(|b| format!("count(*) FILTER (WHERE e.in_state_ms <= {b} * 1000)"))
        .collect();
    let rows = tx.query(
        &format!(
            "SELECT t.spec->'command'->>'agent', count(*), \
             (coalesce(sum(e.in_state_ms), 0) / 1000.0)::float8, ARRAY[{}] \
             FROM events e JOIN tasks t ON t.id = e.task_id WHERE e.from_status = $1 AND e.to_status = $2 GROUP BY 1",
            filters.join(", ")
        ),
        &[&from, &to],
    )?;
    out.push_str(head);
    for agent in AGENTS {
        let row = rows
            .iter()
            .find(|r| r.try_get::<_, Option<&str>>(0).ok().flatten() == Some(agent));
        let (count, sum, buckets): (i64, f64, Vec<i64>) = match row {
            Some(r) => (r.try_get(1)?, r.try_get(2)?, r.try_get(3)?),
            None => (0, 0.0, vec![0; BUCKETS.len()]),
        };
        for (b, n) in BUCKETS.iter().zip(buckets) {
            let _ = writeln!(out, "{name}_bucket{{agent=\"{agent}\",le=\"{b}\"}} {n}");
        }
        let _ = write!(
            out,
            "{name}_bucket{{agent=\"{agent}\",le=\"+Inf\"}} {count}\n\
             {name}_sum{{agent=\"{agent}\"}} {sum}\n{name}_count{{agent=\"{agent}\"}} {count}\n"
        );
    }
    Ok(())
}

/// Live leases past their deadline by state, and the slots they hold.
fn leases(
    tx: &mut Transaction<'_>,
    out: &mut String,
    declared_slots: Option<u32>,
) -> Result<(), QueueError> {
    out.push_str(
        "# HELP exec_pool_lease_overdue Live attempts past their lease deadline that no reconcile has expired.\n\
         # TYPE exec_pool_lease_overdue gauge\n",
    );
    let overdue = tx.query(
        &format!(
            "SELECT status, count(*) FROM attempts \
             WHERE status IN {LIVE} AND lease_deadline <= now() GROUP BY status"
        ),
        &[],
    )?;
    for state in ["leased", "running", "checkpointing"] {
        let mut n = 0_i64;
        for r in &overdue {
            if r.try_get::<_, &str>(0)? == state {
                n = r.try_get(1)?;
            }
        }
        let _ = writeln!(out, "exec_pool_lease_overdue{{state=\"{state}\"}} {n}");
    }
    // one live attempt per slot (attempts_slot_live), so live attempts are busy slots
    let busy: i64 = tx
        .query_one(
            &format!("SELECT count(*) FROM attempts WHERE status IN {LIVE}"),
            &[],
        )?
        .try_get(0)?;
    let _ = write!(
        out,
        "# HELP exec_pool_slots Slots by state: busy holds a live lease.\n\
         # TYPE exec_pool_slots gauge\nexec_pool_slots{{state=\"busy\"}} {busy}\n"
    );
    if let Some(n) = declared_slots {
        let _ = write!(
            out,
            "# HELP exec_pool_slots_declared Slots this host's configuration declares.\n\
             # TYPE exec_pool_slots_declared gauge\nexec_pool_slots_declared {n}\n"
        );
    }
    Ok(())
}
