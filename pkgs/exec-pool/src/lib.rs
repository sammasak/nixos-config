//! The execution pool's data contract (docs/records/execution-pool-contract.md): what a queue stores about a task and
//! its attempts, what a host declares about a slot, and the one function that moves an attempt between states.
//! Every record carries `schema_version`, rejects unknown fields (so a token or secret field cannot ride along) and is
//! checked by `validate()` before anything acts on it. A version or path that is wrong does not deserialise at all.

pub mod agent;
pub mod queue;
pub mod runner;
mod state;
pub mod sync;
pub mod task_result;
pub mod wake;
pub mod workspace;

use std::collections::BTreeSet;
use std::path::{Component, Path};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

pub use state::{Event, Kind, ParkReason, Resolution, Settle, transition};

/// The only schema version this crate reads or writes.
pub const SCHEMA_VERSION: u32 = 1;

/// The record format: only [`SCHEMA_VERSION`] deserialises, so a record of another version cannot exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u32", into = "u32")]
pub struct SchemaVersion(u32);

impl SchemaVersion {
    pub const CURRENT: Self = Self(SCHEMA_VERSION);
}

impl Default for SchemaVersion {
    fn default() -> Self {
        Self::CURRENT
    }
}

impl TryFrom<u32> for SchemaVersion {
    type Error = Error;

    fn try_from(v: u32) -> Result<Self, Error> {
        if v == SCHEMA_VERSION {
            Ok(Self(v))
        } else {
            Err(Error::SchemaVersion(v))
        }
    }
}

impl From<SchemaVersion> for u32 {
    fn from(v: SchemaVersion) -> Self {
        v.0
    }
}

/// A non-empty relative path with no `..` or NUL; nothing else deserialises.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RelPath(String);

impl RelPath {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for RelPath {
    type Error = Error;

    fn try_from(p: String) -> Result<Self, Error> {
        let path = Path::new(&p);
        let bad = p.is_empty()
            || p.contains('\0')
            || path.is_absolute()
            || path
                .components()
                .any(|c| !matches!(c, Component::Normal(_) | Component::CurDir));
        if bad {
            Err(Error::Path(p))
        } else {
            Ok(Self(p))
        }
    }
}

impl From<RelPath> for String {
    fn from(p: RelPath) -> Self {
        p.0
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("schema_version {0} is not {SCHEMA_VERSION}")]
    SchemaVersion(u32),
    #[error("capability {0:?} is not granted")]
    Capability(String),
    #[error("path {0:?} must be relative, non-empty and free of `..`")]
    Path(String),
    #[error("{0} must not be empty")]
    Empty(&'static str),
    #[error("a {status:?} attempt must {} a placement", if *placed { "have" } else { "not have" })]
    Placement { status: Status, placed: bool },
    #[error("idempotency key {0:?} already names a different task")]
    IdempotencyConflict(String),
    #[error("slot {slot} does not offer capability {capability:?}")]
    SlotCapability { slot: String, capability: String },
    #[error("slot {slot} cannot run agent {agent:?}")]
    Agent { slot: String, agent: Agent },
    #[error("{field} is {wanted:?} on the task, {offered:?} on the slot")]
    Pin {
        field: &'static str,
        wanted: String,
        offered: Option<String>,
    },
    #[error("slot {slot} is {state:?}, not idle")]
    SlotNotIdle { slot: String, state: SlotState },
    #[error("lease epoch {got} is stale, the attempt holds {current}")]
    StaleEpoch { got: u64, current: u64 },
    #[error("{event} is not allowed from {from:?}")]
    IllegalTransition { from: Status, event: &'static str },
    #[error("lease epoch overflow")]
    EpochOverflow,
    #[error("retry.max_attempts must be at least 1")]
    NoAttempts,
    #[error("all {0} attempts are used")]
    AttemptsExhausted(u32),
    #[error("an agent task's id {0:?} makes no branch name (agent::branch)")]
    BranchId(String),
    #[error("the receipt's {0} does not match the settled attempt")]
    Receipt(&'static str),
    /// The parser's message: `serde_json::Error` is not `Eq`.
    #[error("{0}")]
    Json(String),
    #[error("wake: {0}")]
    Wake(String),
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Agent {
    None,
    Claude,
    Codex,
    Pi,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Queued,
    Leased,
    Running,
    Checkpointing,
    Waiting,
    Succeeded,
    Failed,
    NeedsReview,
    /// Its submitter called it off: at once while queued or waiting, by its runner's settle once running.
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SlotState {
    Idle,
    Busy,
    Draining,
    Failed,
    Quarantined,
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Succeeded,
    Failed,
    NeedsReview,
}

/// What a task requires of the slot and what an attempt recorded running; reserved for compatibility-aware upgrades.
/// A pin left `None` on a task accepts any slot.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pins {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nix_closure_digest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skill_revision: Option<String>,
}

impl Pins {
    const fn fields(&self) -> [(&'static str, Option<&String>); 4] {
        [
            ("runner_version", self.runner_version.as_ref()),
            ("nix_closure_digest", self.nix_closure_digest.as_ref()),
            ("agent_version", self.agent_version.as_ref()),
            ("skill_revision", self.skill_revision.as_ref()),
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub repo: String,
    pub rev: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    pub agent: Agent,
    pub argv: Vec<String>,
    /// Relative to the task's checkout.
    pub workdir: RelPath,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RetryPolicy {
    pub max_attempts: u32,
}

/// `credential_class` names a policy the host resolves; the credential itself never enters the queue.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskSpec {
    pub schema_version: SchemaVersion,
    pub id: String,
    pub idempotency_key: String,
    pub source: Source,
    pub command: Command,
    pub capabilities: BTreeSet<String>,
    pub resource_class: String,
    pub credential_class: String,
    pub retry: RetryPolicy,
    #[serde(default)]
    pub pins: Pins,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Attempt {
    pub schema_version: SchemaVersion,
    pub id: String,
    pub task_id: String,
    pub lease_epoch: u64,
    /// Leases charged against `retry.max_attempts`: every lease, less those that ended in a planned pause (a settle
    /// to `waiting`), so a resume after a wake is not a retry.
    #[serde(default)]
    pub tries: u32,
    pub status: Status,
    /// Set while leased, running or checkpointing, and kept on `needs_review` for whoever reconciles it.
    pub placement: Option<Placement>,
    #[serde(default)]
    pub pins: Pins,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Placement {
    pub host: String,
    pub slot: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub schema_version: SchemaVersion,
    pub host: String,
    pub id: String,
    pub state: SlotState,
    pub capabilities: BTreeSet<String>,
    pub agents: BTreeSet<Agent>,
    #[serde(default)]
    pub pins: Pins,
    /// The host can pull a parked session's tree from the store ([`STORE`]), and pushes its own there.
    #[serde(default)]
    pub store: bool,
}

/// An opaque, versioned pointer to a checkpoint manifest; its contents are not part of this contract yet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointRef {
    pub schema_version: SchemaVersion,
    pub uri: String,
    pub digest: String,
    /// The lease epoch of the turn that wrote it; 0 in a checkpoint from before sessions.
    #[serde(default)]
    pub generation: u64,
    /// The hosts that hold it.
    #[serde(default)]
    pub hosts: Vec<String>,
}

/// One external effect an attempt reports, e.g. `kind = "github_pr"`, `id = "sammasak/nixos-config#649"`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Effect {
    pub kind: String,
    pub id: String,
}

/// What an attempt reports it did; it counts only with the `settle` accepted at the same `lease_epoch`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub schema_version: SchemaVersion,
    pub task_id: String,
    pub attempt_id: String,
    pub lease_epoch: u64,
    pub outcome: Outcome,
    pub effects: Vec<Effect>,
    pub checkpoint: Option<CheckpointRef>,
}

const fn non_empty(field: &'static str, value: &str) -> Result<(), Error> {
    if value.is_empty() {
        Err(Error::Empty(field))
    } else {
        Ok(())
    }
}

/// Reads `schema_version` first: a newer record with fields this one lacks is a version mismatch, not a malformed
/// record.
fn parse_versioned<T: DeserializeOwned>(json: &str) -> Result<T, Error> {
    #[derive(Deserialize)]
    struct Versioned {
        schema_version: u32,
    }
    SchemaVersion::try_from(serde_json::from_str::<Versioned>(json)?.schema_version)?;
    Ok(serde_json::from_str(json)?)
}

impl TaskSpec {
    /// Parses and validates one task as submitted.
    ///
    /// # Errors
    /// Malformed JSON, an unknown schema version (before any other field is read), an unknown field, or anything
    /// [`TaskSpec::validate`] rejects.
    pub fn parse(json: &str, granted: &BTreeSet<String>) -> Result<Self, Error> {
        let task: Self = parse_versioned(json)?;
        task.validate(granted)?;
        Ok(task)
    }

    /// # Errors
    /// An empty `id`, `idempotency_key`, `source.repo`, `source.rev` or `command.argv`, an agent task whose id
    /// [`agent::branch`] refuses, a zero `retry.max_attempts`, or a capability outside `granted`.
    pub fn validate(&self, granted: &BTreeSet<String>) -> Result<(), Error> {
        non_empty("id", &self.id)?;
        if self.command.agent != Agent::None && agent::branch(self).is_err() {
            return Err(Error::BranchId(self.id.clone()));
        }
        non_empty("idempotency_key", &self.idempotency_key)?;
        non_empty("source.repo", &self.source.repo)?;
        non_empty("source.rev", &self.source.rev)?;
        if self.command.argv.is_empty() {
            return Err(Error::Empty("command.argv"));
        }
        if self.retry.max_attempts == 0 {
            return Err(Error::NoAttempts);
        }
        self.capabilities
            .difference(granted)
            .next()
            .map_or(Ok(()), |c| Err(Error::Capability(c.clone())))
    }

    /// Whether `slot` may run this task now: idle, offering the agent, every capability and every pin the task sets.
    ///
    /// # Errors
    /// The first unmet requirement.
    pub fn fits(&self, slot: &Slot) -> Result<(), Error> {
        if slot.state != SlotState::Idle {
            return Err(Error::SlotNotIdle {
                slot: slot.id.clone(),
                state: slot.state,
            });
        }
        if !slot.agents.contains(&self.command.agent) {
            return Err(Error::Agent {
                slot: slot.id.clone(),
                agent: self.command.agent,
            });
        }
        if let Some(c) = self.capabilities.difference(&slot.capabilities).next() {
            return Err(Error::SlotCapability {
                slot: slot.id.clone(),
                capability: c.clone(),
            });
        }
        for ((field, wanted), (_, offered)) in
            self.pins.fields().into_iter().zip(slot.pins.fields())
        {
            if let Some(w) = wanted.filter(|w| offered != Some(*w)) {
                return Err(Error::Pin {
                    field,
                    wanted: w.clone(),
                    offered: offered.cloned(),
                });
            }
        }
        Ok(())
    }
}

/// What the queue does with a validated submission. Delivery is at-least-once, so a resubmission of the same task
/// under its key is expected and returns the task already queued.
#[derive(Debug, PartialEq, Eq)]
pub enum Submission<'a> {
    New,
    Duplicate(&'a TaskSpec),
}

/// # Errors
/// [`Error::IdempotencyConflict`] when `task`'s key already names a different task.
pub fn submit<'a>(known: &'a [TaskSpec], task: &TaskSpec) -> Result<Submission<'a>, Error> {
    match known
        .iter()
        .find(|k| k.idempotency_key == task.idempotency_key)
    {
        None => Ok(Submission::New),
        Some(k) if k == task => Ok(Submission::Duplicate(k)),
        Some(_) => Err(Error::IdempotencyConflict(task.idempotency_key.clone())),
    }
}

impl Attempt {
    /// # Errors
    /// What [`parse_versioned`] or [`Attempt::validate`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let a: Self = parse_versioned(json)?;
        a.validate()?;
        Ok(a)
    }

    /// # Errors
    /// An empty `id`, `task_id` or placement field, or a placement that disagrees with the status: required while
    /// leased, running or checkpointing, absent while queued or waiting.
    pub fn validate(&self) -> Result<(), Error> {
        non_empty("id", &self.id)?;
        non_empty("task_id", &self.task_id)?;
        if let Some(p) = &self.placement {
            non_empty("placement.host", &p.host)?;
            non_empty("placement.slot", &p.slot)?;
        }
        let placed = match self.status {
            Status::Leased | Status::Running | Status::Checkpointing => true,
            Status::Queued | Status::Waiting => false,
            Status::Succeeded | Status::Failed | Status::NeedsReview | Status::Cancelled => {
                return Ok(());
            }
        };
        if placed == self.placement.is_some() {
            Ok(())
        } else {
            Err(Error::Placement {
                status: self.status,
                placed,
            })
        }
    }
}

impl Slot {
    /// # Errors
    /// What [`parse_versioned`] or [`Slot::validate`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let s: Self = parse_versioned(json)?;
        s.validate()?;
        Ok(s)
    }

    /// # Errors
    /// An empty `host` or `id`.
    pub fn validate(&self) -> Result<(), Error> {
        non_empty("host", &self.host)?;
        non_empty("id", &self.id)
    }
}

impl CheckpointRef {
    /// # Errors
    /// An empty `uri` or `digest`.
    pub fn validate(&self) -> Result<(), Error> {
        non_empty("uri", &self.uri)?;
        non_empty("digest", &self.digest)
    }
}

/// The name in [`CheckpointRef::hosts`] of the always-on store a parked tree is pushed to.
pub const STORE: &str = "store";

/// Whether a runner on `host` may claim an attempt with `checkpoint`; a host without the tree would start afresh.
///
/// Any host before the first park (no checkpoint, or one that names no host, as one from before sessions); after it,
/// a host that holds the tree, or, when `store` says `host` can pull from the store, any host while the store does.
#[must_use]
pub fn reachable(checkpoint: Option<&CheckpointRef>, host: &str, store: bool) -> bool {
    checkpoint.is_none_or(|c| {
        c.hosts.is_empty() || c.hosts.iter().any(|h| h == host || (store && h == STORE))
    })
}

impl Receipt {
    /// # Errors
    /// What [`parse_versioned`] or [`Receipt::validate`] rejects.
    pub fn parse(json: &str) -> Result<Self, Error> {
        let r: Self = parse_versioned(json)?;
        r.validate()?;
        Ok(r)
    }

    /// Whether this receipt belongs to `settled`, the attempt as a terminal settle left it: the same task, attempt
    /// and lease epoch, and the outcome it settled to. A receipt goes with no other event.
    ///
    /// # Errors
    /// [`Error::Receipt`] naming the first field that disagrees.
    pub fn settles(&self, settled: &Attempt) -> Result<(), Error> {
        let outcome = match settled.status {
            Status::Succeeded => Outcome::Succeeded,
            Status::Failed => Outcome::Failed,
            Status::NeedsReview => Outcome::NeedsReview,
            _ => return Err(Error::Receipt("outcome")),
        };
        [
            ("task_id", self.task_id == settled.task_id),
            ("attempt_id", self.attempt_id == settled.id),
            ("lease_epoch", self.lease_epoch == settled.lease_epoch),
            ("outcome", self.outcome == outcome),
        ]
        .into_iter()
        .find(|(_, ok)| !ok)
        .map_or(Ok(()), |(field, _)| Err(Error::Receipt(field)))
    }

    /// # Errors
    /// An empty `task_id` or `attempt_id`, or what [`CheckpointRef::validate`] rejects.
    pub fn validate(&self) -> Result<(), Error> {
        non_empty("task_id", &self.task_id)?;
        non_empty("attempt_id", &self.attempt_id)?;
        self.checkpoint
            .as_ref()
            .map_or(Ok(()), CheckpointRef::validate)
    }
}
