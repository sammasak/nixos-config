use serde::{Deserialize, Serialize};

use crate::{Attempt, Error, Placement, RetryPolicy, Status};

/// Where a checkpoint leaves an attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settle {
    Waiting,
    Queued,
    Succeeded,
    Failed,
    NeedsReview,
    /// The runner stopped the run for a cancel its submitter asked for; it carries no receipt.
    Cancelled,
    /// The runner stopped the run before its agent started because its host powers off: it goes back to the queue
    /// with its try given back, as the host, not the task, ended it. It carries no receipt.
    Drained,
    /// The runner stopped the run after its agent started because its host powers off: what it did by then (a push,
    /// a pull request) is unknown, so it goes to review, never replayed, as a lost lease does. Its receipt says so.
    Interrupted,
}

/// How an operator closes a `needs_review` attempt once they know what its effects were. Only an explicit
/// [`Kind::Resolve`] does this; nothing resolves a review automatically.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    Succeeded,
    Failed,
    /// The effects did not happen: run it again, if an attempt is left.
    Queued,
    /// A session's owner sent it a message: its next turn runs with the try given back, whatever its effects were.
    /// `send_message` (migration 0009) is what does this, for sessions only; this is its model.
    Resume,
}

/// Why a session's turn parked it in `waiting`; a bounded code, the event's reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ParkReason {
    TurnEnd,
    WaitingUntil,
    Preempted,
    HostDraining,
    TurnError,
}

impl ParkReason {
    pub const ALL: [Self; 5] = [
        Self::TurnEnd,
        Self::WaitingUntil,
        Self::Preempted,
        Self::HostDraining,
        Self::TurnError,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TurnEnd => "turn_end",
            Self::WaitingUntil => "waiting_until",
            Self::Preempted => "preempted",
            Self::HostDraining => "host_draining",
            Self::TurnError => "turn_error",
        }
    }
}

/// One change to an attempt, under the lease epoch it was decided on.
///
/// An epoch that is not the attempt's current one was decided on a state that has moved on (a holder whose lease
/// expired, a re-delivered lease), and the event is rejected whatever the state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub epoch: u64,
    pub kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Lease(Placement),
    Start,
    Checkpoint,
    Settle(Settle),
    /// A session's turn ended: running or checkpointing to `waiting`, the try given back.
    Park(ParkReason),
    Wake,
    Expire,
    Resolve(Resolution),
}

impl Kind {
    const fn name(&self) -> &'static str {
        match self {
            Self::Lease(_) => "lease",
            Self::Start => "start",
            Self::Checkpoint => "checkpoint",
            Self::Settle(_) => "settle",
            Self::Park(_) => "park",
            Self::Wake => "wake",
            Self::Expire => "expire",
            Self::Resolve(_) => "resolve",
        }
    }
}

/// The attempt after `event`, or why it may not happen; `attempt` itself is never changed.
///
/// A lease bumps the epoch. So does an expiry, which reconciles instead of retrying: a lease whose `start` was never
/// accepted goes back to `queued`, one that was running or checkpointing goes to `needs_review`, as its effects are
/// unknown. That is only safe while a runner begins no work before its `start` is accepted.
///
/// Every lease counts against `retry.max_attempts` but one that settles or parks to `waiting`, that a drain sends
/// back to the queue, or that a resume gives back. An expiry or a retry with no
/// attempt left fails the attempt instead of queueing it, so neither loops forever; an operator's resolve to `queued`
/// with none left is refused.
///
/// # Errors
/// What [`Attempt::validate`] rejects before or after the event, [`Error::StaleEpoch`],
/// [`Error::IllegalTransition`], [`Error::AttemptsExhausted`] or [`Error::EpochOverflow`].
pub fn transition(attempt: &Attempt, retry: &RetryPolicy, event: &Event) -> Result<Attempt, Error> {
    attempt.validate()?;
    if event.epoch != attempt.lease_epoch {
        return Err(Error::StaleEpoch {
            got: event.epoch,
            current: attempt.lease_epoch,
        });
    }
    let bumped = || {
        attempt
            .lease_epoch
            .checked_add(1)
            .ok_or(Error::EpochOverflow)
    };
    let mut next = attempt.clone();
    match (attempt.status, &event.kind) {
        (Status::Queued, Kind::Lease(placement)) => {
            if attempt.tries >= retry.max_attempts {
                return Err(Error::AttemptsExhausted(retry.max_attempts));
            }
            next.tries = attempt.tries.saturating_add(1);
            next.lease_epoch = bumped()?;
            next.status = Status::Leased;
            next.placement = Some(placement.clone());
        }
        (Status::Leased, Kind::Start) => next.status = Status::Running,
        (Status::Running, Kind::Checkpoint) => next.status = Status::Checkpointing,
        (Status::Checkpointing, Kind::Settle(to)) => {
            next.status = match to {
                Settle::Waiting => {
                    next.tries = attempt.tries.saturating_sub(1);
                    Status::Waiting
                }
                Settle::Queued => Status::Queued,
                Settle::Drained => {
                    next.tries = attempt.tries.saturating_sub(1);
                    Status::Queued
                }
                Settle::Succeeded => Status::Succeeded,
                Settle::Failed => Status::Failed,
                Settle::NeedsReview | Settle::Interrupted => Status::NeedsReview,
                Settle::Cancelled => Status::Cancelled,
            };
        }
        (Status::Running | Status::Checkpointing, Kind::Park(_)) => {
            next.tries = attempt.tries.saturating_sub(1);
            next.status = Status::Waiting;
        }
        (Status::Waiting, Kind::Wake) => next.status = Status::Queued,
        (Status::Leased | Status::Running | Status::Checkpointing, Kind::Expire) => {
            next.lease_epoch = bumped()?;
            next.status = if attempt.status == Status::Leased {
                Status::Queued
            } else {
                Status::NeedsReview
            };
        }
        (Status::NeedsReview, Kind::Resolve(to)) => {
            next.status = match to {
                Resolution::Succeeded => Status::Succeeded,
                Resolution::Failed => Status::Failed,
                Resolution::Queued if attempt.tries >= retry.max_attempts => {
                    return Err(Error::AttemptsExhausted(retry.max_attempts));
                }
                Resolution::Queued => Status::Queued,
                Resolution::Resume => {
                    next.tries = attempt.tries.saturating_sub(1);
                    Status::Queued
                }
            };
        }
        (from, kind) => {
            return Err(Error::IllegalTransition {
                from,
                event: kind.name(),
            });
        }
    }
    if next.status == Status::Queued && next.tries >= retry.max_attempts {
        next.status = Status::Failed;
    }
    if matches!(next.status, Status::Queued | Status::Waiting) {
        next.placement = None;
    }
    next.validate()?;
    Ok(next)
}
