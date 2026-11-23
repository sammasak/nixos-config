use std::collections::BTreeSet;

use exec_pool::{
    Agent, Attempt, CheckpointRef, Error, Event, Kind, Pins, Placement, Receipt, RelPath,
    Resolution, RetryPolicy, SchemaVersion, Settle, Slot, SlotState, Status, Submission, TaskSpec,
    submit, transition,
};
use serde_json::{Value, json};

fn task_json() -> Value {
    json!({
        "schema_version": 1,
        "id": "t-1",
        "idempotency_key": "issue-649-fixture",
        "source": { "repo": "sammasak/nixos-config", "rev": "2e423b7" },
        "command": { "agent": "none", "argv": ["true"], "workdir": "pkgs/exec-pool" },
        "capabilities": ["read_only"],
        "resource_class": "small",
        "credential_class": "none",
        "retry": { "max_attempts": 2 },
        "pins": { "nix_closure_digest": "sha256-closure-a" }
    })
}

fn granted() -> BTreeSet<String> {
    BTreeSet::from(["read_only".to_owned(), "network".to_owned()])
}

fn parse(v: &Value) -> Result<TaskSpec, Error> {
    TaskSpec::parse(&v.to_string(), &granted())
}

#[expect(
    clippy::unwrap_used,
    reason = "a fixture that does not parse fails every test using it"
)]
fn task() -> TaskSpec {
    parse(&task_json()).unwrap()
}

fn slot() -> Slot {
    Slot {
        schema_version: SchemaVersion::CURRENT,
        host: "msi-ms7758".to_owned(),
        id: "s0".to_owned(),
        state: SlotState::Idle,
        capabilities: granted(),
        agents: BTreeSet::from([Agent::None, Agent::Claude]),
        pins: Pins {
            nix_closure_digest: Some("sha256-closure-a".to_owned()),
            ..Pins::default()
        },
    }
}

fn queued() -> Attempt {
    Attempt {
        schema_version: SchemaVersion::CURRENT,
        id: "a-1".to_owned(),
        task_id: "t-1".to_owned(),
        lease_epoch: 0,
        tries: 0,
        status: Status::Queued,
        placement: None,
        pins: Pins::default(),
    }
}

/// Enough attempts for every path below; `max_attempts_stop_retries` tests the limit.
const RETRY: RetryPolicy = RetryPolicy { max_attempts: 3 };

const fn ev(epoch: u64, kind: Kind) -> Event {
    Event { epoch, kind }
}

fn lease(epoch: u64) -> Event {
    ev(
        epoch,
        Kind::Lease(Placement {
            host: "msi-ms7758".to_owned(),
            slot: "s0".to_owned(),
        }),
    )
}

fn step(a: &Attempt, kind: Kind) -> Result<Attempt, Error> {
    transition(a, &RETRY, &ev(a.lease_epoch, kind))
}

/// Each event at the attempt's epoch of the moment, as the one current holder sends it.
fn run(kinds: &[Kind]) -> Result<Attempt, Error> {
    kinds.iter().try_fold(queued(), |a, k| step(&a, k.clone()))
}

fn placed() -> Kind {
    lease(0).kind
}

#[test]
fn valid_task_parses_fits_and_round_trips() {
    let t = task();
    assert_eq!(t.command.agent, Agent::None);
    t.fits(&slot()).unwrap();
    let again: TaskSpec = serde_json::from_value(serde_json::to_value(&t).unwrap()).unwrap();
    assert_eq!(again, t);
    assert_eq!(serde_json::to_value(&t).unwrap(), task_json());
}

fn attempt_json() -> Value {
    json!({ "schema_version": 1, "id": "a-1", "task_id": "t-1", "lease_epoch": 0, "status": "queued", "placement": null })
}

fn json_error<T: serde::de::DeserializeOwned + std::fmt::Debug>(v: Value) -> String {
    // empty when it deserialised, which no expected message is contained in
    serde_json::from_value::<T>(v)
        .err()
        .map(|e| e.to_string())
        .unwrap_or_default()
}

#[test]
fn incompatible_schema_version_does_not_deserialise_on_any_record() {
    let mut v = task_json();
    v["schema_version"] = json!(2);
    assert_eq!(parse(&v), Err(Error::SchemaVersion(2)));
    let want = |v: u32| Error::SchemaVersion(v).to_string();
    assert!(json_error::<TaskSpec>(v).contains(&want(2)));

    let mut a = attempt_json();
    a["schema_version"] = json!(0);
    assert!(json_error::<Attempt>(a).contains(&want(0)));
    let mut s = serde_json::to_value(slot()).unwrap();
    s["schema_version"] = json!(2);
    assert!(json_error::<Slot>(s).contains(&want(2)));
    let receipt = json!({
        "schema_version": 1, "task_id": "t-1", "attempt_id": "a-1", "lease_epoch": 1, "outcome": "succeeded",
        "effects": [], "checkpoint": { "schema_version": 9, "uri": "checkpoint://t-1/1", "digest": "sha256-x" }
    });
    assert!(json_error::<Receipt>(receipt).contains(&want(9)));
    assert_eq!(SchemaVersion::try_from(1), Ok(SchemaVersion::CURRENT));
}

#[test]
fn empty_fields_are_rejected() {
    for (path, field) in [
        (&["id"][..], "id"),
        (&["idempotency_key"], "idempotency_key"),
        (&["source", "repo"], "source.repo"),
        (&["source", "rev"], "source.rev"),
    ] {
        let mut v = task_json();
        match path {
            [k] => v[*k] = json!(""),
            [k, l] => v[*k][*l] = json!(""),
            _ => unreachable!(),
        }
        assert_eq!(parse(&v), Err(Error::Empty(field)), "{field}");
    }
    let mut v = task_json();
    v["command"]["argv"] = json!([]);
    assert_eq!(parse(&v), Err(Error::Empty("command.argv")));

    let mut a = queued();
    a.id = String::new();
    assert_eq!(a.validate(), Err(Error::Empty("id")));
    let mut a = queued();
    a.task_id = String::new();
    assert_eq!(a.validate(), Err(Error::Empty("task_id")));
    let mut a = run(&[placed()]).unwrap();
    a.placement = Some(Placement {
        host: "msi-ms7758".to_owned(),
        slot: String::new(),
    });
    assert_eq!(a.validate(), Err(Error::Empty("placement.slot")));
    let mut s = slot();
    s.host = String::new();
    assert_eq!(s.validate(), Err(Error::Empty("host")));
    let mut s = slot();
    s.id = String::new();
    assert_eq!(s.validate(), Err(Error::Empty("id")));
    let cp = |uri: &str, digest: &str| CheckpointRef {
        schema_version: SchemaVersion::CURRENT,
        uri: uri.to_owned(),
        digest: digest.to_owned(),
    };
    assert_eq!(cp("", "d").validate(), Err(Error::Empty("uri")));
    assert_eq!(cp("u", "").validate(), Err(Error::Empty("digest")));
    let receipt: Receipt = serde_json::from_value(json!({
        "schema_version": 1, "task_id": "t-1", "attempt_id": "", "lease_epoch": 1, "outcome": "succeeded",
        "effects": [], "checkpoint": null
    }))
    .unwrap();
    assert_eq!(receipt.validate(), Err(Error::Empty("attempt_id")));
    let receipt = Receipt {
        attempt_id: "a-1".to_owned(),
        checkpoint: Some(cp("u", "")),
        ..receipt
    };
    assert_eq!(receipt.validate(), Err(Error::Empty("digest")));
}

#[test]
fn placement_must_agree_with_status() {
    // running without a placement: deserialises, but neither validates nor moves
    let mut a = attempt_json();
    a["status"] = json!("running");
    a["lease_epoch"] = json!(1);
    let running: Attempt = serde_json::from_value(a).unwrap();
    let missing = Err(Error::Placement {
        status: Status::Running,
        placed: true,
    });
    assert_eq!(running.validate(), missing);
    assert_eq!(step(&running, Kind::Checkpoint).map(|_| ()), missing);
    for status in [Status::Leased, Status::Checkpointing] {
        let a = Attempt {
            status,
            ..running.clone()
        };
        assert!(matches!(
            a.validate(),
            Err(Error::Placement { placed: true, .. })
        ));
    }

    // queued or waiting with one
    let leased = run(&[placed()]).unwrap();
    for status in [Status::Queued, Status::Waiting] {
        let a = Attempt {
            status,
            ..leased.clone()
        };
        let stray = Err(Error::Placement {
            status,
            placed: false,
        });
        assert_eq!(a.validate(), stray);
        assert_eq!(step(&a, placed()).map(|_| ()), stray);
    }
}

#[test]
fn unauthorised_capability_is_rejected() {
    let mut v = task_json();
    v["capabilities"] = json!(["read_only", "github_write"]);
    assert_eq!(parse(&v), Err(Error::Capability("github_write".to_owned())));

    let mut s = slot();
    s.capabilities.remove("read_only");
    assert_eq!(
        task().fits(&s),
        Err(Error::SlotCapability {
            slot: "s0".to_owned(),
            capability: "read_only".to_owned()
        })
    );
}

#[test]
fn invalid_paths_are_rejected() {
    for bad in ["", "/etc", "../x", "a/../../b", "a\0b"] {
        assert_eq!(
            RelPath::try_from(bad.to_owned()),
            Err(Error::Path(bad.to_owned()))
        );
        let mut v = task_json();
        v["command"]["workdir"] = json!(bad);
        let want = Error::Path(bad.to_owned()).to_string();
        assert!(
            matches!(parse(&v), Err(Error::Json(m)) if m.contains(&want)),
            "{bad:?}"
        );
        assert!(json_error::<TaskSpec>(v).contains(&want), "{bad:?}");
    }
    for good in [".", "a/b", "./a"] {
        let mut v = task_json();
        v["command"]["workdir"] = json!(good);
        parse(&v).unwrap();
    }
}

#[test]
fn newer_version_with_new_fields_is_a_version_mismatch() {
    let mut v = task_json();
    v["schema_version"] = json!(2);
    v["deadline"] = json!("2027-01-01");
    assert_eq!(parse(&v), Err(Error::SchemaVersion(2)));
}

#[test]
fn secret_and_unknown_fields_are_rejected() {
    for field in ["token", "secret", "github_token"] {
        let mut v = task_json();
        v[field] = json!("x");
        assert!(
            matches!(parse(&v), Err(Error::Json(m)) if m.contains("unknown field")),
            "{field}"
        );
    }
    for nested in ["command", "source", "pins", "retry"] {
        let mut v = task_json();
        v[nested]["token"] = json!("x");
        assert!(
            matches!(parse(&v), Err(Error::Json(m)) if m.contains("unknown field")),
            "{nested}.token"
        );
    }
}

#[test]
fn duplicate_idempotency_key() {
    let known = vec![task()];
    assert_eq!(
        submit(&known, &task()),
        Ok(Submission::Duplicate(&known[0]))
    );
    let mut other = task();
    other.id = "t-2".to_owned();
    assert_eq!(
        submit(&known, &other),
        Err(Error::IdempotencyConflict("issue-649-fixture".to_owned()))
    );
    other.idempotency_key = "another".to_owned();
    assert_eq!(submit(&known, &other), Ok(Submission::New));
}

#[test]
fn incompatible_agent_or_closure_digest() {
    let mut v = task_json();
    v["command"]["agent"] = json!("codex");
    assert_eq!(
        parse(&v).unwrap().fits(&slot()),
        Err(Error::Agent {
            slot: "s0".to_owned(),
            agent: Agent::Codex
        })
    );

    let mut s = slot();
    s.pins.nix_closure_digest = Some("sha256-closure-b".to_owned());
    assert_eq!(
        task().fits(&s),
        Err(Error::Pin {
            field: "nix_closure_digest",
            wanted: "sha256-closure-a".to_owned(),
            offered: Some("sha256-closure-b".to_owned()),
        })
    );
    s.pins.nix_closure_digest = None;
    assert!(matches!(
        task().fits(&s),
        Err(Error::Pin { offered: None, .. })
    ));

    let mut busy = slot();
    busy.state = SlotState::Draining;
    assert!(matches!(task().fits(&busy), Err(Error::SlotNotIdle { .. })));
}

#[test]
fn happy_path_and_every_settle() {
    let at = run(&[placed(), Kind::Start, Kind::Checkpoint]).unwrap();
    assert_eq!((at.status, at.lease_epoch), (Status::Checkpointing, 1));
    assert_eq!(at.placement.as_ref().map(|p| p.slot.as_str()), Some("s0"));
    for (to, want) in [
        (Settle::Waiting, Status::Waiting),
        (Settle::Queued, Status::Queued),
        (Settle::Succeeded, Status::Succeeded),
        (Settle::Failed, Status::Failed),
        (Settle::NeedsReview, Status::NeedsReview),
    ] {
        assert_eq!(step(&at, Kind::Settle(to)).unwrap().status, want);
    }
    let waiting = step(&at, Kind::Settle(Settle::Waiting)).unwrap();
    assert_eq!(waiting.placement, None);
    assert_eq!(
        step(&at, Kind::Settle(Settle::Queued)).unwrap().placement,
        None
    );
    let woken = step(&waiting, Kind::Wake).unwrap();
    assert_eq!(woken.status, Status::Queued);
    assert_eq!(step(&woken, placed()).unwrap().lease_epoch, 2);
}

#[test]
fn stale_epoch_is_rejected() {
    // lease 1 expires before its start is accepted; lease 3 runs. Holder 1's events are the ones holder 3 may send.
    let expired = run(&[placed(), Kind::Expire]).unwrap();
    assert_eq!((expired.status, expired.lease_epoch), (Status::Queued, 2));
    assert_eq!(
        transition(&expired, &RETRY, &ev(1, Kind::Start)),
        Err(Error::StaleEpoch { got: 1, current: 2 })
    );
    let second = run(&[
        placed(),
        Kind::Expire,
        placed(),
        Kind::Start,
        Kind::Checkpoint,
    ])
    .unwrap();
    assert_eq!(second.lease_epoch, 3);
    for kind in [
        Kind::Checkpoint,
        Kind::Settle(Settle::Succeeded),
        Kind::Expire,
    ] {
        assert_eq!(
            transition(&second, &RETRY, &ev(1, kind)),
            Err(Error::StaleEpoch { got: 1, current: 3 })
        );
    }
    assert_eq!(
        transition(&second, &RETRY, &ev(3, Kind::Settle(Settle::Succeeded)))
            .unwrap()
            .status,
        Status::Succeeded
    );
    // a lease re-delivered after the expiry it raced with
    assert_eq!(
        transition(&expired, &RETRY, &lease(0)),
        Err(Error::StaleEpoch { got: 0, current: 2 })
    );
}

#[test]
fn expired_lease_is_reconciled_not_duplicated() {
    let back = run(&[placed(), Kind::Expire]).unwrap();
    assert_eq!((back.status, back.placement), (Status::Queued, None));

    for upto in [2, 3] {
        let path = [placed(), Kind::Start, Kind::Checkpoint];
        let a = run(&path[..upto]).unwrap();
        let reconciled = step(&a, Kind::Expire).unwrap();
        assert_eq!(
            (reconciled.status, reconciled.lease_epoch),
            (Status::NeedsReview, 2),
            "expired from {:?}",
            a.status
        );
        assert_eq!(reconciled.placement, a.placement, "kept for review");
        for kind in [placed(), Kind::Wake, Kind::Start] {
            assert!(matches!(
                step(&reconciled, kind),
                Err(Error::IllegalTransition {
                    from: Status::NeedsReview,
                    ..
                })
            ));
        }
    }
}

#[test]
fn illegal_transitions() {
    let illegal = |a: &Attempt, k: Kind| matches!(step(a, k), Err(Error::IllegalTransition { from, .. }) if from == a.status);
    let settled = |to| run(&[placed(), Kind::Start, Kind::Checkpoint, Kind::Settle(to)]).unwrap();
    let q = queued();
    for k in [
        Kind::Start,
        Kind::Wake,
        Kind::Expire,
        Kind::Settle(Settle::Queued),
    ] {
        assert!(illegal(&q, k));
    }
    let leased = run(&[placed()]).unwrap();
    assert!(illegal(&leased, placed()));
    assert!(illegal(&leased, Kind::Checkpoint));
    let running = run(&[placed(), Kind::Start]).unwrap();
    assert!(illegal(&running, Kind::Settle(Settle::Succeeded)));
    assert!(illegal(&running, Kind::Start));
    let waiting = settled(Settle::Waiting);
    assert!(illegal(&waiting, placed()));
    assert!(illegal(&waiting, Kind::Expire));
    for to in [Settle::Succeeded, Settle::Failed, Settle::NeedsReview] {
        let done = settled(to);
        for k in [
            placed(),
            Kind::Start,
            Kind::Wake,
            Kind::Expire,
            Kind::Settle(to),
        ] {
            assert!(illegal(&done, k.clone()), "{k:?} after {to:?}");
        }
    }
}

#[test]
fn status_spelling_is_snake_case() {
    assert_eq!(
        serde_json::to_value(Status::NeedsReview).unwrap(),
        json!("needs_review")
    );
    assert_eq!(
        serde_json::to_value(SlotState::Quarantined).unwrap(),
        json!("quarantined")
    );
    let a: Attempt = serde_json::from_value(json!({
        "schema_version": 1, "id": "a", "task_id": "t", "lease_epoch": 3, "status": "needs_review",
        "placement": { "host": "asus-b460m", "slot": "s1" }, "pins": { "agent_version": "2.1.311" }
    }))
    .unwrap();
    a.validate().unwrap();
    assert_eq!(a.pins.agent_version.as_deref(), Some("2.1.311"));
}

#[test]
fn max_attempts_stop_retries() {
    let once = RetryPolicy { max_attempts: 1 };
    let leased = transition(&queued(), &once, &lease(0)).unwrap();
    assert_eq!(leased.tries, 1);
    // an expired lease with no attempt left fails instead of looping back to queued
    let expired = transition(&leased, &once, &ev(1, Kind::Expire)).unwrap();
    assert_eq!((expired.status, expired.lease_epoch), (Status::Failed, 2));
    // so does a retry the runner asks for
    let at = [Kind::Start, Kind::Checkpoint]
        .into_iter()
        .try_fold(leased, |a, k| transition(&a, &once, &ev(1, k)))
        .unwrap();
    let retried = transition(&at, &once, &ev(1, Kind::Settle(Settle::Queued))).unwrap();
    assert_eq!(retried.status, Status::Failed);
    // and a record claiming a lease left is still refused one past the limit
    let mut spent = queued();
    spent.tries = 1;
    assert_eq!(
        transition(&spent, &once, &lease(0)),
        Err(Error::AttemptsExhausted(1))
    );
    // with two, the first expiry requeues
    let two = RetryPolicy { max_attempts: 2 };
    let a = transition(&queued(), &two, &lease(0)).unwrap();
    assert_eq!(
        transition(&a, &two, &ev(1, Kind::Expire)).unwrap().status,
        Status::Queued
    );

    let mut v = task_json();
    v["retry"]["max_attempts"] = json!(0);
    assert_eq!(parse(&v), Err(Error::NoAttempts));
}

#[test]
fn needs_review_is_resolved_only_explicitly() {
    let review = run(&[placed(), Kind::Start, Kind::Expire]).unwrap();
    assert_eq!(review.status, Status::NeedsReview);
    for (to, want) in [
        (Resolution::Succeeded, Status::Succeeded),
        (Resolution::Failed, Status::Failed),
        (Resolution::Queued, Status::Queued),
    ] {
        assert_eq!(step(&review, Kind::Resolve(to)).unwrap().status, want);
    }
    let requeued = step(&review, Kind::Resolve(Resolution::Queued)).unwrap();
    assert_eq!(requeued.placement, None);
    // a resolve decided before the expiry it raced with is stale
    assert_eq!(
        transition(
            &review,
            &RETRY,
            &ev(1, Kind::Resolve(Resolution::Succeeded))
        ),
        Err(Error::StaleEpoch { got: 1, current: 2 })
    );
    // nothing else resolves it, and nothing but needs_review takes a resolve
    let running = run(&[placed(), Kind::Start]).unwrap();
    assert!(matches!(
        step(&running, Kind::Resolve(Resolution::Succeeded)),
        Err(Error::IllegalTransition {
            from: Status::Running,
            event: "resolve"
        })
    ));
}

#[test]
fn lease_with_an_empty_placement_is_refused() {
    for (host, slot, field) in [
        ("", "s0", "placement.host"),
        ("msi-ms7758", "", "placement.slot"),
    ] {
        let lease = Kind::Lease(Placement {
            host: host.to_owned(),
            slot: slot.to_owned(),
        });
        assert_eq!(step(&queued(), lease), Err(Error::Empty(field)));
    }
}

#[test]
fn every_record_parses_version_first() {
    let a = attempt_json();
    assert_eq!(Attempt::parse(&a.to_string()).unwrap(), queued());
    let mut newer = a.clone();
    newer["schema_version"] = json!(2);
    newer["deadline"] = json!("x");
    assert_eq!(
        Attempt::parse(&newer.to_string()),
        Err(Error::SchemaVersion(2))
    );
    let mut bad = a;
    bad["id"] = json!("");
    assert_eq!(Attempt::parse(&bad.to_string()), Err(Error::Empty("id")));

    let s = serde_json::to_value(slot()).unwrap();
    assert_eq!(Slot::parse(&s.to_string()).unwrap(), slot());
    let mut newer = s;
    newer["schema_version"] = json!(3);
    newer["drain_at"] = json!(1);
    assert_eq!(
        Slot::parse(&newer.to_string()),
        Err(Error::SchemaVersion(3))
    );

    let r = receipt_json();
    Receipt::parse(&r.to_string()).unwrap();
    let mut newer = r;
    newer["schema_version"] = json!(2);
    newer["cost"] = json!(1);
    assert_eq!(
        Receipt::parse(&newer.to_string()),
        Err(Error::SchemaVersion(2))
    );
}

fn receipt_json() -> Value {
    json!({
        "schema_version": 1, "task_id": "t-1", "attempt_id": "a-1", "lease_epoch": 1, "outcome": "succeeded",
        "effects": [{ "kind": "github_pr", "id": "sammasak/nixos-config#651" }], "checkpoint": null
    })
}

#[test]
fn receipt_belongs_to_its_settle() {
    let at = run(&[placed(), Kind::Start, Kind::Checkpoint]).unwrap();
    let done = step(&at, Kind::Settle(Settle::Succeeded)).unwrap();
    let r = Receipt::parse(&receipt_json().to_string()).unwrap();
    r.settles(&done).unwrap();
    for (field, value) in [
        ("task_id", json!("t-2")),
        ("attempt_id", json!("a-2")),
        ("lease_epoch", json!(3)),
        ("outcome", json!("failed")),
    ] {
        let mut v = receipt_json();
        v[field] = value;
        let other = Receipt::parse(&v.to_string()).unwrap();
        assert_eq!(other.settles(&done), Err(Error::Receipt(field)), "{field}");
    }
    // a receipt goes with a terminal settle only
    let waiting = step(&at, Kind::Settle(Settle::Waiting)).unwrap();
    assert_eq!(r.settles(&waiting), Err(Error::Receipt("outcome")));
}

#[test]
fn a_planned_pause_is_not_a_retry() {
    let once = RetryPolicy { max_attempts: 1 };
    let at = [placed(), Kind::Start, Kind::Checkpoint]
        .into_iter()
        .try_fold(queued(), |a, k| {
            let e = a.lease_epoch;
            transition(&a, &once, &ev(e, k))
        })
        .unwrap();
    let waiting = transition(&at, &once, &ev(1, Kind::Settle(Settle::Waiting))).unwrap();
    assert_eq!(waiting.tries, 0);
    let woken = transition(&waiting, &once, &ev(1, Kind::Wake)).unwrap();
    assert_eq!(woken.status, Status::Queued);
    assert_eq!(transition(&woken, &once, &lease(1)).unwrap().tries, 1);

    // an operator cannot requeue a review with no attempt left
    let review = transition(
        &transition(
            &transition(&queued(), &once, &lease(0)).unwrap(),
            &once,
            &ev(1, Kind::Start),
        )
        .unwrap(),
        &once,
        &ev(1, Kind::Expire),
    )
    .unwrap();
    assert_eq!(
        transition(&review, &once, &ev(2, Kind::Resolve(Resolution::Queued))),
        Err(Error::AttemptsExhausted(1))
    );
    assert_eq!(
        transition(&review, &once, &ev(2, Kind::Resolve(Resolution::Failed)))
            .unwrap()
            .status,
        Status::Failed
    );
}
