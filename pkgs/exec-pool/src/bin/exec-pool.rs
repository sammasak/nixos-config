//! `exec-pool`: submit an agent task to the queue and watch it, for a user `homelab.postgresql.clients` lets log in
//! as `exec_pool_submit`, whose grants (migration 0002) allow inserting a queued task and reading the queue, nothing
//! else. It reaches the queue over the Unix socket in `EXEC_POOL_DB`, by default [`DB`]. Exit codes are
//! `exec-pool-queue`'s: 0 done, 1 refused, 2 usage, 3 outcome unknown (run `status` before submitting again), 75
//! database unavailable.

use std::collections::{BTreeMap, BTreeSet};
use std::process::ExitCode;

use exec_pool::queue::{QueueError, Store, Submitted};
use exec_pool::{Agent, Command, Pins, RelPath, RetryPolicy, SchemaVersion, Source, TaskSpec};
use serde_json::{Value, json};

const DB: &str = "host=/run/postgresql dbname=exec_pool user=exec_pool_submit";
const USAGE: &str = "usage: exec-pool COMMAND
  submit --agent claude|codex|pi --repo URL --rev REV --workdir PATH --prompt TEXT [--model M] [--key K]
        prints the task id. The checkout of REV at URL is cloned into the slot and the agent runs in PATH, relative
        to it. K is the idempotency key, by default derived from the rest: the same submission again is the same
        task, so give a new --key to run it once more.
  status [ID]       the task (or attempt) ID with its events, or the number of attempts in each status
  list [--limit N]  the newest N tasks (20), newest first";

enum Fail {
    Usage(String),
    Queue(QueueError),
}

impl From<QueueError> for Fail {
    fn from(e: QueueError) -> Self {
        Self::Queue(e)
    }
}

struct Args {
    flags: BTreeMap<String, String>,
    positional: Vec<String>,
}

impl Args {
    fn parse(rest: &[String]) -> Result<Self, Fail> {
        let mut args = Self {
            flags: BTreeMap::new(),
            positional: Vec::new(),
        };
        let mut it = rest.iter();
        while let Some(arg) = it.next() {
            let Some(key) = arg.strip_prefix("--") else {
                args.positional.push(arg.clone());
                continue;
            };
            let value = it
                .next()
                .ok_or_else(|| Fail::Usage(format!("--{key} needs a value")))?;
            if args.flags.insert(key.to_owned(), value.clone()).is_some() {
                return Err(Fail::Usage(format!("--{key} given twice")));
            }
        }
        Ok(args)
    }

    fn get(&self, key: &str) -> Result<&str, Fail> {
        self.opt(key)
            .ok_or_else(|| Fail::Usage(format!("--{key} is required")))
    }

    fn opt(&self, key: &str) -> Option<&str> {
        self.flags.get(key).map(String::as_str)
    }

    /// Refuses a flag `cmd` does not take, so a misspelt `--modle` is not silently dropped.
    fn only(&self, cmd: &str, known: &[&str], positional: usize) -> Result<(), Fail> {
        if let Some(k) = self.flags.keys().find(|k| !known.contains(&k.as_str())) {
            return Err(Fail::Usage(format!("{cmd} takes no --{k}")));
        }
        if self.positional.len() > positional {
            return Err(Fail::Usage(format!(
                "{cmd}: unexpected {:?}",
                self.positional
            )));
        }
        Ok(())
    }
}

/// FNV-1a: stable across Rust releases, unlike `DefaultHasher`, so a resubmission by a newer binary keeps its key.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The task `submit`'s flags describe. Its id follows from its key, so a resubmission under the key is the same
/// [`TaskSpec`] and the queue returns the task it already has.
fn task_spec(args: &Args) -> Result<TaskSpec, Fail> {
    args.only(
        "submit",
        &["agent", "repo", "rev", "workdir", "prompt", "model", "key"],
        0,
    )?;
    let agent_name = args.get("agent")?;
    let agent = match serde_json::from_value(Value::String(agent_name.to_owned())) {
        Ok(Agent::None) | Err(_) => {
            return Err(Fail::Usage(format!(
                "--agent {agent_name:?} is not claude, codex or pi"
            )));
        }
        Ok(a) => a,
    };
    let (repo, rev, workdir, prompt) = (
        args.get("repo")?,
        args.get("rev")?,
        args.get("workdir")?,
        args.get("prompt")?,
    );
    let model = args.opt("model");
    let key = args.opt("key").map_or_else(
        || {
            let what = json!([agent, repo, rev, workdir, prompt, model]).to_string();
            format!("cli:{:016x}", fnv1a(what.as_bytes()))
        },
        str::to_owned,
    );
    let task = TaskSpec {
        schema_version: SchemaVersion::CURRENT,
        id: format!("cli-{:016x}", fnv1a(key.as_bytes())),
        idempotency_key: key,
        source: Source {
            repo: repo.to_owned(),
            rev: rev.to_owned(),
        },
        command: Command {
            agent,
            argv: std::iter::once(prompt)
                .chain(model)
                .map(str::to_owned)
                .collect(),
            workdir: RelPath::try_from(workdir.to_owned())
                .map_err(|e| Fail::Usage(format!("--workdir: {e}")))?,
        },
        capabilities: BTreeSet::new(),
        resource_class: "small".to_owned(),
        credential_class: "slot".to_owned(),
        // an agent's effects are not known to be safe to replay
        retry: RetryPolicy { max_attempts: 1 },
        pins: Pins::default(),
    };
    task.validate(&BTreeSet::new())
        .map_err(|e| Fail::Usage(e.to_string()))?;
    exec_pool::agent::argv(&task).map_err(|e| Fail::Usage(e.to_string()))?;
    Ok(task)
}

fn run(cmd: &str, args: &Args, store: &mut Store) -> Result<(), Fail> {
    match cmd {
        "submit" => {
            let task = task_spec(args)?;
            if let Submitted::Duplicate { .. } = store.submit(&task)? {
                eprintln!("exec-pool: already queued under its key");
            }
            println!("{}", task.id);
        }
        "status" => {
            args.only("status", &[], 1)?;
            match args.positional.first() {
                None => println!("{}", store.counts()?),
                Some(id) => println!(
                    "{}",
                    store
                        .task(id)?
                        .ok_or_else(|| QueueError::NotFound(id.clone()))?
                ),
            }
        }
        "list" => {
            args.only("list", &["limit"], 0)?;
            let limit = args.opt("limit").map_or(Ok(20), |n| {
                n.parse::<i64>()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| Fail::Usage("--limit must be a positive number".to_owned()))
            })?;
            store.tasks(limit)?.iter().for_each(|t| println!("{t}"));
        }
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
        let conninfo = std::env::var("EXEC_POOL_DB").unwrap_or_else(|_| DB.to_owned());
        run(cmd, &args, &mut Store::open(&conninfo)?)
    })();
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(Fail::Usage(m)) => {
            eprintln!("exec-pool: {m}\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Fail::Queue(e)) => {
            eprintln!("exec-pool: {e}");
            ExitCode::from(match e {
                QueueError::Unavailable(_) => 75,
                QueueError::OutcomeUnknown(_) => 3,
                _ => 1,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::panic,
        reason = "a failure is the test failing"
    )]

    use super::*;

    fn args(a: &[&str]) -> Args {
        let v: Vec<String> = a.iter().map(|s| (*s).to_owned()).collect();
        Args::parse(&v).unwrap_or_else(|_| panic!("parse {a:?}"))
    }

    fn spec(a: &[&str]) -> Result<TaskSpec, String> {
        task_spec(&args(a)).map_err(|e| match e {
            Fail::Usage(m) => m,
            Fail::Queue(e) => e.to_string(),
        })
    }

    const BASE: [&str; 10] = [
        "--agent",
        "claude",
        "--repo",
        "https://github.com/sammasak/nixos-config.git",
        "--rev",
        "abc123",
        "--workdir",
        "pkgs/exec-pool",
        "--prompt",
        "fix the test",
    ];

    fn with(extra: &[&'static str]) -> Vec<&'static str> {
        BASE.iter().chain(extra).copied().collect()
    }

    #[test]
    fn flags_map_to_a_queued_one_attempt_agent_task() {
        let t = spec(&with(&["--model", "opus"])).unwrap();
        assert_eq!(t.command.agent, Agent::Claude);
        assert_eq!(t.command.argv, ["fix the test", "opus"]);
        assert_eq!(t.command.workdir.as_str(), "pkgs/exec-pool");
        assert_eq!(
            t.source.repo,
            "https://github.com/sammasak/nixos-config.git"
        );
        assert_eq!(t.source.rev, "abc123");
        assert_eq!(t.retry.max_attempts, 1);
        assert!(t.capabilities.is_empty());
        assert_eq!(spec(&BASE).unwrap().command.argv, ["fix the test"]);
    }

    #[test]
    fn the_key_is_derived_from_the_task_unless_given() {
        let a = spec(&BASE).unwrap();
        assert_eq!(spec(&BASE).unwrap(), a);
        assert!(a.idempotency_key.starts_with("cli:"));
        let other = spec(&with(&["--model", "opus"])).unwrap();
        assert_ne!(other.idempotency_key, a.idempotency_key);
        assert_ne!(other.id, a.id);
        let keyed = spec(&with(&["--key", "run-2"])).unwrap();
        assert_eq!(keyed.idempotency_key, "run-2");
        assert_ne!(keyed.id, a.id);
        assert_eq!(spec(&with(&["--key", "run-2"])).unwrap().id, keyed.id);
    }

    #[test]
    fn bad_flags_are_refused() {
        let mut no_rev = BASE.to_vec();
        no_rev.drain(4..6);
        for (a, want) in [
            (no_rev, "--rev is required"),
            (with(&["--modle", "opus"]), "submit takes no --modle"),
            (with(&["--model", "-x"]), "model \"-x\""),
            (with(&["extra"]), "unexpected"),
        ] {
            let got = spec(&a).unwrap_err();
            assert!(got.contains(want), "{a:?}: {got}");
        }
        let mut bad = BASE.to_vec();
        for (i, v, want) in [
            (1, "none", "is not claude"),
            (7, "../x", "--workdir"),
            (7, "/abs", "--workdir"),
            (9, "", "argv"),
        ] {
            let old = std::mem::replace(&mut bad[i], v);
            let got = spec(&bad).unwrap_err();
            assert!(got.contains(want), "{v:?}: {got}");
            bad[i] = old;
        }
    }
}
