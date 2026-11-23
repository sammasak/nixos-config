use crate::{Attempt, Error, Placement, RetryPolicy, Status};

/// Where a checkpoint leaves an attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settle {
    Waiting,
    Queued,
    Succeeded,
    Failed,
    NeedsReview,
}

/// How an operator closes a `needs_review` attempt once they know what its effects were. Only an explicit
/// [`Kind::Resolve`] does this; nothing resolves a review automatically.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resolution {
    Succeeded,
    Failed,
    /// The effects did not happen: run it again, if an attempt is left.
    Queued,
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
/// Every lease counts against `retry.max_attempts` but one that settles to `waiting`. An expiry or a retry with no
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
                Settle::Succeeded => Status::Succeeded,
                Settle::Failed => Status::Failed,
                Settle::NeedsReview => Status::NeedsReview,
            };
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
