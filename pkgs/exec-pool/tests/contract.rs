use std::collections::BTreeSet;

use exec_pool::{
    Agent, Attempt, CheckpointRef, Error, Event, Kind, Outcome, Pins, Placement, Receipt, Settle,
    Slot, SlotState, Status, Submission, TaskSpec, submit, transition,
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
        schema_version: 1,
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
        schema_version: 1,
        id: "a-1".to_owned(),
        task_id: "t-1".to_owned(),
        lease_epoch: 0,
        status: Status::Queued,
        placement: None,
        pins: Pins::default(),
    }
}

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
    transition(a, &ev(a.lease_epoch, kind))
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

#[test]
fn incompatible_schema_version_is_rejected_on_every_record() {
    let mut v = task_json();
    v["schema_version"] = json!(2);
    assert_eq!(parse(&v), Err(Error::SchemaVersion(2)));

    let mut a = queued();
    a.schema_version = 0;
    assert_eq!(a.validate(), Err(Error::SchemaVersion(0)));
    let mut s = slot();
    s.schema_version = 2;
    assert_eq!(s.validate(), Err(Error::SchemaVersion(2)));
    let receipt = Receipt {
        schema_version: 1,
        task_id: "t-1".to_owned(),
        attempt_id: "a-1".to_owned(),
        lease_epoch: 1,
        outcome: Outcome::Succeeded,
        effects: vec![],
        checkpoint: Some(CheckpointRef {
            schema_version: 9,
            uri: "checkpoint://t-1/1".to_owned(),
            digest: "sha256-x".to_owned(),
        }),
    };
    assert_eq!(receipt.validate(), Err(Error::SchemaVersion(9)));
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
        let mut v = task_json();
        v["command"]["workdir"] = json!(bad);
        assert_eq!(parse(&v), Err(Error::Path(bad.to_owned())), "{bad:?}");
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
        transition(&expired, &ev(1, Kind::Start)),
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
            transition(&second, &ev(1, kind)),
            Err(Error::StaleEpoch { got: 1, current: 3 })
        );
    }
    assert_eq!(
        transition(&second, &ev(3, Kind::Settle(Settle::Succeeded)))
            .unwrap()
            .status,
        Status::Succeeded
    );
    // a lease re-delivered after the expiry it raced with
    assert_eq!(
        transition(&expired, &lease(0)),
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
