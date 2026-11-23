use crate::{Attempt, Error, Placement, Status};

/// Where a checkpoint leaves an attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settle {
    Waiting,
    Queued,
    Succeeded,
    Failed,
    NeedsReview,
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
        }
    }
}

/// The attempt after `event`, or why it may not happen; `attempt` itself is never changed.
///
/// A lease bumps the epoch. So does an expiry, which reconciles instead of retrying: a lease whose `start` was never
/// accepted goes back to `queued`, one that was running or checkpointing goes to `needs_review`, as its effects are
/// unknown. That is only safe while a runner begins no work before its `start` is accepted.
///
/// # Errors
/// [`Error::StaleEpoch`], [`Error::IllegalTransition`], or [`Error::EpochOverflow`].
pub fn transition(attempt: &Attempt, event: &Event) -> Result<Attempt, Error> {
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
            next.lease_epoch = bumped()?;
            next.status = Status::Leased;
            next.placement = Some(placement.clone());
        }
        (Status::Leased, Kind::Start) => next.status = Status::Running,
        (Status::Running, Kind::Checkpoint) => next.status = Status::Checkpointing,
        (Status::Checkpointing, Kind::Settle(to)) => {
            next.status = match to {
                Settle::Waiting => Status::Waiting,
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
        (from, kind) => {
            return Err(Error::IllegalTransition {
                from,
                event: kind.name(),
            });
        }
    }
    if matches!(next.status, Status::Queued | Status::Waiting) {
        next.placement = None;
    }
    Ok(next)
}
