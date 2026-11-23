//! `exec-pool-queue`: the queue's host-local CLI. It reaches PostgreSQL over the Unix socket in `EXEC_POOL_DB` (a
//! libpq conninfo, e.g. `host=/run/postgresql dbname=exec_pool user=exec_pool`), so the database's peer
//! authentication is its authentication. Each state change is one JSON line on stdout; a command's result is one
//! more, marked `"result"`. Exit 0 done, 1 refused, 2 usage, 3 outcome unknown (the connection was lost while
//! committing: read the state, never replay blindly), 75 database unavailable (nothing changed, retry later).

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::process::ExitCode;

use exec_pool::queue::{Change, METRICS_UNAVAILABLE, QueueError, Store, Submitted};
use exec_pool::{Event, Kind, Receipt, Resolution, Settle, Slot, TaskSpec};
use serde_json::json;

const USAGE: &str = "usage: exec-pool-queue COMMAND [--flag value]...
  migrate | migrate-down
  submit --granted CAP,CAP < task.json
  claim --lease-secs N < slot.json
  live < slot.json                                              (the attempt live on a slot: after exit 3 on a claim)
  start | checkpoint | wake --attempt ID --epoch N
  heartbeat --attempt ID --epoch N --lease-secs N
  settle --attempt ID --epoch N --to waiting|queued|succeeded|failed|needs_review [< receipt.json, terminal only]
  resolve --attempt ID --epoch N --to succeeded|failed|queued   (an operator closing a needs_review attempt)
  reconcile                                                     (expire overdue leases; run at startup)
  metrics       (Prometheus text for a textfile collector; install stdout whatever the exit code: on a failure it is
                exec_pool_queue_up 0, so the queue reads absent instead of keeping the last good counts)";

enum Fail {
    Usage(String),
    Queue(QueueError),
}

impl From<QueueError> for Fail {
    fn from(e: QueueError) -> Self {
        Self::Queue(e)
    }
}

impl From<exec_pool::Error> for Fail {
    fn from(e: exec_pool::Error) -> Self {
        Self::Queue(e.into())
    }
}

struct Args(BTreeMap<String, String>);

impl Args {
    fn parse(rest: &[String]) -> Result<Self, Fail> {
        let mut map = BTreeMap::new();
        let mut it = rest.iter();
        while let Some(flag) = it.next() {
            let key = flag
                .strip_prefix("--")
                .ok_or_else(|| Fail::Usage(format!("unexpected {flag:?}")))?;
            let value = it
                .next()
                .ok_or_else(|| Fail::Usage(format!("--{key} needs a value")))?;
            if map.insert(key.to_owned(), value.clone()).is_some() {
                return Err(Fail::Usage(format!("--{key} given twice")));
            }
        }
        Ok(Self(map))
    }

    fn get(&self, key: &str) -> Result<&str, Fail> {
        self.0
            .get(key)
            .map(String::as_str)
            .ok_or_else(|| Fail::Usage(format!("--{key} is required")))
    }

    fn num<T: std::str::FromStr>(&self, key: &str) -> Result<T, Fail> {
        self.get(key)?
            .parse()
            .map_err(|_| Fail::Usage(format!("--{key} must be a number")))
    }
}

fn stdin() -> Result<String, Fail> {
    let mut s = String::new();
    std::io::stdin()
        .read_to_string(&mut s)
        .map_err(|e| Fail::Usage(format!("reading stdin: {e}")))?;
    Ok(s)
}

fn log(c: &Change) {
    println!("{}", json!({ "msg": "state_change", "change": c }));
}

fn result(v: &serde_json::Value) {
    println!("{}", json!({ "result": v }));
}

fn event(args: &Args, kind: Kind) -> Result<Event, Fail> {
    Ok(Event {
        epoch: args.num("epoch")?,
        kind,
    })
}

fn run(cmd: &str, args: &Args, store: &mut Store) -> Result<(), Fail> {
    let apply = |store: &mut Store, kind: Kind, receipt: Option<&Receipt>| -> Result<(), Fail> {
        let (attempt, change) = store.apply(args.get("attempt")?, &event(args, kind)?, receipt)?;
        log(&change);
        result(&json!({ "status": attempt.status, "lease_epoch": attempt.lease_epoch }));
        Ok(())
    };
    match cmd {
        "migrate" => store.migrate()?,
        "migrate-down" => store.migrate_down()?,
        "submit" => {
            let granted: BTreeSet<String> = args
                .get("granted")?
                .split(',')
                .filter(|c| !c.is_empty())
                .map(str::to_owned)
                .collect();
            match store.submit(&TaskSpec::parse(&stdin()?, &granted)?)? {
                Submitted::New { attempt, change } => {
                    log(&change);
                    result(&json!({ "attempt": attempt, "duplicate": false }));
                }
                Submitted::Duplicate { attempt } => {
                    result(&json!({ "attempt": attempt, "duplicate": true }));
                }
            }
        }
        "claim" => match store.claim(&Slot::parse(&stdin()?)?, args.num("lease-secs")?)? {
            Some(claim) => {
                log(&claim.change);
                result(&json!({ "task": claim.task, "attempt": claim.attempt }));
            }
            None => result(&json!(null)),
        },
        "live" => result(&json!(store.live_on(&Slot::parse(&stdin()?)?)?)),
        "start" => apply(store, Kind::Start, None)?,
        "checkpoint" => apply(store, Kind::Checkpoint, None)?,
        "wake" => apply(store, Kind::Wake, None)?,
        "heartbeat" => store.heartbeat(
            args.get("attempt")?,
            args.num("epoch")?,
            args.num("lease-secs")?,
        )?,
        "settle" => {
            let to = match args.get("to")? {
                "waiting" => Settle::Waiting,
                "queued" => Settle::Queued,
                "succeeded" => Settle::Succeeded,
                "failed" => Settle::Failed,
                "needs_review" => Settle::NeedsReview,
                other => return Err(Fail::Usage(format!("--to {other:?}"))),
            };
            let receipt = match to {
                Settle::Waiting | Settle::Queued => None,
                _ => Some(Receipt::parse(&stdin()?)?),
            };
            apply(store, Kind::Settle(to), receipt.as_ref())?;
        }
        "resolve" => {
            let to = match args.get("to")? {
                "succeeded" => Resolution::Succeeded,
                "failed" => Resolution::Failed,
                "queued" => Resolution::Queued,
                other => return Err(Fail::Usage(format!("--to {other:?}"))),
            };
            apply(store, Kind::Resolve(to), None)?;
        }
        "reconcile" => {
            let changes = store.reconcile()?;
            changes.iter().for_each(log);
            result(&json!({ "expired": changes.len() }));
        }
        "metrics" => match store.metrics() {
            Ok(text) => print!("{text}"),
            Err(e) => {
                print!("{METRICS_UNAVAILABLE}");
                return Err(e.into());
            }
        },
        other => return Err(Fail::Usage(format!("unknown command {other:?}"))),
    }
    Ok(())
}

fn main() -> ExitCode {
    let cli: Vec<String> = std::env::args().skip(1).collect();
    let outcome = (|| {
        let (cmd, rest) = cli
            .split_first()
            .ok_or_else(|| Fail::Usage("no command".to_owned()))?;
        let args = Args::parse(rest)?;
        let conninfo = std::env::var("EXEC_POOL_DB")
            .map_err(|_| Fail::Usage("EXEC_POOL_DB is not set".to_owned()))?;
        run(cmd, &args, &mut Store::open(&conninfo)?)
    })();
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(Fail::Usage(m)) => {
            eprintln!("exec-pool-queue: {m}\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Fail::Queue(e)) => {
            eprintln!("exec-pool-queue: {e}");
            ExitCode::from(match e {
                QueueError::Unavailable(_) => 75,
                QueueError::OutcomeUnknown(_) => 3,
                _ => 1,
            })
        }
    }
}
