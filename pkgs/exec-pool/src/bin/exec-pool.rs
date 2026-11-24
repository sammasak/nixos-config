//! `exec-pool`: submit an agent task to the queue and watch it, for a user `homelab.postgresql.clients` lets log in
//! as `exec_pool_submit`, whose grants (migrations 0002 and 0005) allow queueing a task through `submit_task`,
//! cancelling one it queued through `cancel_task`, starting a session through `start_session` and messaging it through
//! `send_message` (migration 0009) and `send_timer` (0014), and reading the queue without its prompts, nothing else. It reaches the queue over the Unix socket in `EXEC_POOL_DB`, by default [`DB`], or, with a unit's `db-password` credential, over TCP. Exit codes are
//! `exec-pool-queue`'s: 0 done, 1 refused, 2 usage, 3 outcome unknown (run `status` before submitting again), 75
//! database unavailable; `wait` adds 124, not settled by its timeout.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use exec_pool::queue::{QueueError, Store};
use exec_pool::{Agent, Command, Pins, RelPath, RetryPolicy, SchemaVersion, Source, TaskSpec};
use exec_pool::{pane, wake};
use jiff::ZonedDateTime;
use serde_json::{Value, json};

const DB: &str = "host=/run/postgresql dbname=exec_pool user=exec_pool_submit";
const USAGE: &str = "usage: exec-pool COMMAND
  submit --agent claude|codex|pi --repo URL --rev REV --workdir PATH --prompt TEXT|--prompt-file FILE [--model M]
        [--key K] [--priority N]
        prints the task id. The checkout of REV at URL is cloned into the slot and the agent runs in PATH, relative
        to it. FILE - reads the prompt from stdin, which no shell re-splits (an ssh command line). K is the idempotency key, by default derived from the rest: the same submission again is the same
        task, so give a new --key to run it once more. N, -100 to 100 (0), orders the claim: higher first, and a
        queued task gains one for every 10 minutes it waits, so a low one still runs; a running task is never stopped
        for another. The same key again keeps the priority it was first given.
  start             submit's flags, claude only: starts a session, whose first turn runs the prompt and parks it
                    waiting; prints its id
  send ID [--at HH:MM|RFC3339] --prompt TEXT|--prompt-file FILE
                    the session's next turn runs TEXT: a waiting session (or one in needs_review, which this resumes)
                    is queued for it, a running one takes it once its turn ends. With --at, a timer: TEXT is delivered
                    from that time (HH:MM: the next one, local time), when it queues a waiting session; it resumes
                    none in needs_review. Prints the attempt and its status
  attach ID [--timeout SECS]
                    wakes the session into a slot's Herdr pane with no message of yours (it is told the owner opened
                    it) and prints the host, slot and Herdr agent to open, once its turn runs (600 s by default)
  status [ID]       the task (or attempt) ID with its events, or the number of attempts in each status
  list [--limit N]  the newest N tasks (20), newest first; a session's shows why it waits (parked)
  result ID         the task's state and, once the runner recorded it, its result (a session's last turn): the
                    agent's outcome, the exit code and up to 16 KiB of output (Claude's result text, or the end of
                    stdout)
  logs ID [-f|--follow] [--turn N]
                    the agent's output (stdout and stderr as they came) of the task's last turn, or its Nth (from 1,
                    of the turns that logged): the last 256 KiB, as the runner read it at most 10 s ago, whichever host
                    ran it. -f follows it, and a session's next turns, until the task is neither queued nor running
  wait ID [--timeout SECS]
                    blocks until the task settles (succeeded, failed, needs_review or cancelled) or, a session,
                    parks waiting, then prints its result
  sessions [--gc]   one JSON object per line for each session, as the queue decides its removal: task_id, state,
                    last_change, the hosts its tree may be on, dir (its directory's name, as the runner names it),
                    handed_back, eligible and stale; with --gc only the eligible ones, which a remover may delete:
                    only a session whose last turn's branch held its whole tree (handed_back) is (a stale one is
                    kept: its tree may hold unpushed work)
  cancel ID         cancels a task you submitted: a queued one at once; a running one is stopped by its runner within
                    seconds and settles cancelled (follow it with wait). Prints the attempt and its status after";
/// What `attach` tells the session it wakes.
const ATTACH_PROMPT: &str = "The owner opened this session in its pane to work with you: say in one line where you \
are, then wait for their input.";
const ATTACH_TIMEOUT: Duration = Duration::from_secs(600);
/// Flags that take no value.
const SWITCHES: [&str; 2] = ["gc", "follow"];
/// How often `logs -f` reads the queue.
const FOLLOW_POLL: Duration = Duration::from_secs(2);
/// How often `wait` reads the queue, and how long it waits after the settle for the runner to record the result.
const POLL: Duration = Duration::from_secs(5);
const RECORD_GRACE: Duration = Duration::from_secs(30);
/// What `wait` returns on: a settle, or a session's park.
const SETTLED: [&str; 5] = [
    "succeeded",
    "failed",
    "needs_review",
    "cancelled",
    "waiting",
];

enum Fail {
    Usage(String),
    Queue(QueueError),
    TimedOut(Value),
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
            let arg = if arg == "-f" { "--follow" } else { arg };
            let Some(key) = arg.strip_prefix("--") else {
                args.positional.push(arg.to_owned());
                continue;
            };
            let value = if SWITCHES.contains(&key) {
                &String::new()
            } else {
                it.next()
                    .ok_or_else(|| Fail::Usage(format!("--{key} needs a value")))?
            };
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

/// The task `cmd`'s flags describe (`submit`, or `start` for a session), in the one shape `submit_task` (migration
/// 0002) takes. Its id is a placeholder: the queue assigns the real one from the key, so a resubmission under the key
/// returns the task already queued.
fn task_spec(cmd: &str, args: &Args) -> Result<TaskSpec, Fail> {
    let session = cmd == "start";
    args.only(
        cmd,
        &[
            "agent",
            "repo",
            "rev",
            "workdir",
            "prompt",
            "prompt-file",
            "model",
            "key",
            "priority",
        ],
        0,
    )?;
    let agent_name = args.get("agent")?;
    let agent = match serde_json::from_value(Value::String(agent_name.to_owned())) {
        Ok(Agent::None) | Err(_) => {
            return Err(Fail::Usage(format!(
                "--agent {agent_name:?} is not claude, codex or pi"
            )));
        }
        Ok(Agent::Codex | Agent::Pi) if session => {
            return Err(Fail::Usage(format!(
                "--agent {agent_name:?}: a session is claude only"
            )));
        }
        Ok(a) => a,
    };
    let (repo, rev, workdir) = (args.get("repo")?, args.get("rev")?, args.get("workdir")?);
    let prompt = &prompt(args)?;
    let model = args.opt("model");
    let key = args.opt("key").map_or_else(
        || {
            let what = json!([agent, repo, rev, workdir, prompt, model]);
            // a session and a one-shot task of the same flags are two tasks
            let what = if session {
                json!(["session", what])
            } else {
                what
            };
            format!("cli:{:016x}", fnv1a(what.to_string().as_bytes()))
        },
        str::to_owned,
    );
    let task = TaskSpec {
        schema_version: SchemaVersion::CURRENT,
        id: "cli".to_owned(),
        idempotency_key: key,
        source: Source {
            repo: repo.to_owned(),
            rev: rev.to_owned(),
        },
        command: Command {
            agent,
            argv: std::iter::once(prompt.as_str())
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

fn prompt(args: &Args) -> Result<String, Fail> {
    match (args.opt("prompt"), args.opt("prompt-file")) {
        (Some(p), None) => Ok(p.to_owned()),
        (None, Some(f)) => read_prompt(f),
        _ => Err(Fail::Usage(
            "one of --prompt or --prompt-file is required".to_owned(),
        )),
    }
}

fn read_prompt(file: &str) -> Result<String, Fail> {
    let read = if file == "-" {
        std::io::read_to_string(std::io::stdin())
    } else {
        std::fs::read_to_string(file)
    };
    read.map_err(|e| Fail::Usage(format!("--prompt-file {file}: {e}")))
}

fn run(cmd: &str, args: &Args, store: &mut Store) -> Result<(), Fail> {
    match cmd {
        "submit" | "start" => {
            let task = task_spec(cmd, args)?;
            let priority = args.opt("priority").map_or(Ok(0), |n| {
                n.parse::<i32>()
                    .ok()
                    .filter(|n| (-100..=100).contains(n))
                    .ok_or_else(|| Fail::Usage("--priority must be -100 to 100".to_owned()))
            })?;
            let (id, duplicate) = if cmd == "start" {
                store.start_session(&task, priority)?
            } else {
                store.submit_task(&task, priority)?
            };
            if duplicate {
                eprintln!("exec-pool: already submitted under its key; see exec-pool status {id}");
            }
            println!("{id}");
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
        "result" => {
            args.only("result", &[], 1)?;
            println!("{}", shown(store, id(args)?)?);
        }
        "logs" => {
            args.only("logs", &["follow", "turn"], 1)?;
            let turn =
                args.opt("turn")
                    .map(|n| {
                        n.parse::<u32>().ok().filter(|n| *n > 0).ok_or_else(|| {
                            Fail::Usage("--turn must be a positive number".to_owned())
                        })
                    })
                    .transpose()?;
            logs(store, id(args)?, turn, args.opt("follow").is_some())?;
        }
        "wait" => {
            args.only("wait", &["timeout"], 1)?;
            println!("{}", wait(store, id(args)?, timeout(args)?)?);
        }
        "send" => {
            args.only("send", &["prompt", "prompt-file", "at"], 1)?;
            let (attempt, status) = match args.opt("at") {
                None => store.send(id(args)?, &prompt(args)?)?,
                Some(at) => {
                    let due_at = wake::due_at(at, &ZonedDateTime::now())
                        .map_err(|e| Fail::Usage(format!("--at {e}")))?;
                    store.send_timer(id(args)?, &prompt(args)?, &due_at)?
                }
            };
            println!("{}", json!({ "attempt": attempt, "status": status }));
        }
        "attach" => {
            args.only("attach", &["timeout"], 1)?;
            let timeout = timeout(args)?.unwrap_or(ATTACH_TIMEOUT);
            store.send(id(args)?, ATTACH_PROMPT)?;
            println!("{}", attached(store, id(args)?, timeout)?);
        }
        "sessions" => {
            args.only("sessions", &["gc"], 0)?;
            store
                .sessions(args.opt("gc").is_some())?
                .iter()
                .for_each(|s| println!("{s}"));
        }
        "cancel" => {
            args.only("cancel", &[], 1)?;
            let (attempt, status) = store.cancel(id(args)?)?;
            println!("{}", json!({ "attempt": attempt, "status": status }));
        }
        other => return Err(Fail::Usage(format!("unknown command {other:?}"))),
    }
    Ok(())
}

fn timeout(args: &Args) -> Result<Option<Duration>, Fail> {
    args.opt("timeout")
        .map(|n| {
            n.parse()
                .map(Duration::from_secs)
                .map_err(|_| Fail::Usage("--timeout must be a number of seconds".to_owned()))
        })
        .transpose()
}

fn id(args: &Args) -> Result<&str, Fail> {
    args.positional
        .first()
        .map(String::as_str)
        .ok_or_else(|| Fail::Usage("an ID is required".to_owned()))
}

fn shown(store: &mut Store, id: &str) -> Result<Value, Fail> {
    Ok(store
        .result(id)?
        .ok_or_else(|| QueueError::NotFound(id.to_owned()))?)
}

/// Prints turn `turn`'s log (the last one's: `None`), what is new of it at each read when `follow`, and the turns
/// after it while following the last, until the task is neither queued nor running; notes on stderr what the queue
/// no longer holds.
fn logs(store: &mut Store, id: &str, turn: Option<u32>, follow: bool) -> Result<(), Fail> {
    // the turn shown, by its lease epoch, and the offset printed up to
    let mut shown: Option<(u64, u64)> = None;
    loop {
        let found = match store.logs(id, turn) {
            Ok(l) => l,
            Err(QueueError::Unavailable(e) | QueueError::OutcomeUnknown(e)) if follow => {
                eprintln!("exec-pool: {e}; waiting");
                thread::sleep(FOLLOW_POLL);
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        if let Some(t) = &found.turn {
            let from = match shown {
                Some((epoch, at)) if epoch == t.lease_epoch => at,
                _ => {
                    eprintln!(
                        "exec-pool: turn {} of {} (lease epoch {}){}",
                        t.turn,
                        t.turns,
                        t.lease_epoch,
                        if t.live { ", running" } else { "" }
                    );
                    0
                }
            };
            if t.start > from {
                eprintln!(
                    "exec-pool: [{} bytes before this are not kept]",
                    t.start.saturating_sub(from)
                );
            }
            let skip = usize::try_from(from.saturating_sub(t.start)).unwrap_or(usize::MAX);
            let new = t.log.get(skip..).unwrap_or_default();
            io::Write::write_all(&mut io::stdout(), new)
                .and_then(|()| io::Write::flush(&mut io::stdout()))
                .map_err(|e| Fail::Usage(format!("stdout: {e}")))?;
            let end = t
                .start
                .saturating_add(u64::try_from(t.log.len()).unwrap_or(u64::MAX));
            shown = Some((t.lease_epoch, end.max(from)));
        }
        let more = match (&found.turn, turn) {
            (Some(t), Some(_)) => t.live,
            _ => found.pending,
        };
        if !follow || !more {
            if found.turn.is_none() {
                eprintln!("exec-pool: no turn of {id} has logged yet");
            }
            return Ok(());
        }
        thread::sleep(FOLLOW_POLL);
    }
}

/// The session's turn once it runs, where its pane is: host, slot and the agent's name in that host's Herdr.
fn attached(store: &mut Store, id: &str, timeout: Duration) -> Result<Value, Fail> {
    let start = Instant::now();
    loop {
        let v = store
            .task(id)?
            .ok_or_else(|| QueueError::NotFound(id.to_owned()))?;
        let at = |k: &str| v.get(k).and_then(Value::as_str);
        if let (Some("running"), Some(host), Some(slot), Some(task)) =
            (at("status"), at("host"), at("slot"), at("task"))
        {
            let agent = pane::agent_name(task);
            return Ok(json!({
                "task": task, "host": host, "slot": slot, "agent": agent,
                "open": format!("herdr --machine {host} agent get {agent}"),
            }));
        }
        if start.elapsed() >= timeout {
            return Err(Fail::TimedOut(v));
        }
        thread::sleep(POLL);
    }
}

/// Polls until the task is settled and its result recorded, or [`RECORD_GRACE`] after the settle (or at the
/// timeout, once settled); an unavailable database is waited out like the task.
fn wait(store: &mut Store, id: &str, timeout: Option<Duration>) -> Result<Value, Fail> {
    let start = Instant::now();
    let mut settled_at = None;
    let mut last = Value::Null;
    loop {
        match shown(store, id) {
            Ok(v) => {
                let settled = v
                    .get("status")
                    .and_then(Value::as_str)
                    .is_some_and(|s| SETTLED.contains(&s));
                if settled && settled_at.is_none() {
                    settled_at = Some(Instant::now());
                }
                let out_of_time = timeout.is_some_and(|t| start.elapsed() >= t);
                if settled_at.is_some_and(|t| {
                    v.get("result").is_some_and(|r| !r.is_null())
                        || t.elapsed() >= RECORD_GRACE
                        || out_of_time
                }) {
                    return Ok(v);
                }
                if !settled {
                    settled_at = None;
                }
                last = v;
            }
            // a read: an unknown commit changed nothing
            Err(Fail::Queue(QueueError::Unavailable(e) | QueueError::OutcomeUnknown(e))) => {
                eprintln!("exec-pool: {e}; waiting");
            }
            Err(e) => return Err(e),
        }
        let left = timeout.map_or(POLL, |t| t.saturating_sub(start.elapsed()));
        if left.is_zero() {
            return Err(Fail::TimedOut(last));
        }
        thread::sleep(left.min(POLL));
    }
}

fn main() -> ExitCode {
    let cli: Vec<String> = std::env::args().skip(1).collect();
    let outcome = (|| {
        let (cmd, rest) = cli
            .split_first()
            .ok_or_else(|| Fail::Usage("no command".to_owned()))?;
        let args = Args::parse(rest)?;
        let conninfo = std::env::var("EXEC_POOL_DB").unwrap_or_else(|_| DB.to_owned());
        // a unit's db-password credential (LoadCredential), as exec-pool-runner's: another host's queue over TCP
        let password = std::env::var_os("CREDENTIALS_DIRECTORY")
            .map(|dir| std::path::Path::new(&dir).join("db-password"))
            .filter(|p| p.exists())
            .map(|p| {
                std::fs::read(&p).map_err(|e| Fail::Usage(format!("db-password credential: {e}")))
            })
            .transpose()?;
        let mut store = match password {
            Some(pw) => Store::open_remote(&conninfo, pw.strip_suffix(b"\n").unwrap_or(&pw))?,
            None => Store::open(&conninfo)?,
        };
        run(cmd, &args, &mut store)
    })();
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(Fail::Usage(m)) => {
            eprintln!("exec-pool: {m}\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Fail::TimedOut(last)) => {
            println!("{last}");
            eprintln!("exec-pool: not settled by --timeout");
            ExitCode::from(124)
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
        task_spec("submit", &args(a)).map_err(|e| match e {
            Fail::Usage(m) => m,
            Fail::Queue(e) => e.to_string(),
            Fail::TimedOut(v) => v.to_string(),
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
        assert_eq!(
            spec(&with(&["--key", "run-2"])).unwrap().idempotency_key,
            "run-2"
        );
    }

    #[test]
    fn a_session_is_claude_only_and_keyed_apart_from_its_one_shot() {
        let start = |a: &[&str]| task_spec("start", &args(a)).map_err(|_| ());
        let session = start(&BASE).unwrap();
        assert_eq!(session.command, spec(&BASE).unwrap().command);
        assert_ne!(
            session.idempotency_key,
            spec(&BASE).unwrap().idempotency_key
        );
        let mut codex = BASE.to_vec();
        codex[1] = "codex";
        assert!(start(&codex).is_err());
        assert!(spec(&codex).is_ok());
    }

    #[test]
    fn the_prompt_file_is_the_prompt_flag() {
        let file = std::env::temp_dir().join(format!("exec-pool-prompt-{}", std::process::id()));
        std::fs::write(&file, "fix the test").unwrap();
        let mut a: Vec<String> = BASE[..8].iter().map(|s| (*s).to_owned()).collect();
        a.extend(["--prompt-file".to_owned(), file.display().to_string()]);
        let got = task_spec(
            "submit",
            &Args::parse(&a).unwrap_or_else(|_| panic!("parse")),
        )
        .ok();
        std::fs::remove_file(&file).unwrap();
        assert_eq!(got, Some(spec(&BASE).unwrap()));
        for (a, want) in [
            (with(&["--prompt-file", "-"]), "one of --prompt"),
            (BASE[..8].to_vec(), "one of --prompt"),
        ] {
            let got = spec(&a).unwrap_err();
            assert!(got.contains(want), "{a:?}: {got}");
        }
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
