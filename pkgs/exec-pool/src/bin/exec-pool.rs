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
/// The repositories a slot fetches with the token and pushes to (homelab.execPool.repos), one `owner/name` a line, unless
/// `EXEC_POOL_REPOS` names another file; a host without it (a submitter off the queue host) checks none.
const REPOS: &str = "/etc/exec-pool/repos";
const USAGE: &str = "usage: exec-pool COMMAND
  submit --agent claude|codex|pi --repo URL --rev REV --workdir PATH --prompt TEXT|--prompt-file FILE [--model M]
        [--key K] [--priority N] [--requires NAME]...
        prints the task id. The checkout of REV at URL is cloned into the slot and the agent runs in PATH, relative
        to it, and is refused unless it is in the pool's repository list (homelab.execPool.repos, /etc/exec-pool/repos). FILE - reads the prompt from stdin, which no shell re-splits (an ssh command line). K is the idempotency key, by default derived from the rest: the same submission again is the same
        task, so give a new --key to run it once more. N, -100 to 100 (0), orders the claim: higher first, and a
        queued task gains one for every 10 minutes it waits, so a low one still runs; a running task is never stopped
        for another. The same key again keeps the priority it was first given. Each --requires NAME is a capability
        the slot must offer (homelab.execPool.capabilities: github, monitoring, always-on, and host-HOST for the slot's host); a task no slot seen in
        the last day offers them to, with its agent, is refused, naming the capability.
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
  status [ID]       the task (or attempt) ID with its priority and events, or the number of attempts in each status
  list [--limit N]  the newest N tasks (20), newest first, each with its priority; a session's shows why it waits
                    (parked)
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
  sessions [ID] [--limit N] [--merged] [--report FILE]
                    where each session's (and one-shot agent task's) time and money went, one JSON object per line,
                    newest first (N, 20), with its model (its --model, default when none) and session: turns,
                    wall, running, queued, review and waiting seconds (waiting_by_reason: by why its turns parked),
                    the tokens and cost its turns reported, and pr: the pull request of its branch pool/<task> on
                    GitHub as gh finds it ({number, state open|closed|merged, merged_at, url, head}; null with none,
                    and pr_error when gh could not tell), and rescued: true when it merged at another commit than
                    the one the task pushed (head), null when either is not known. --merged: only those whose pull request merged. --report FILE:
                    of those out of a slot and the queue, one line per merged pull request of the branch that FILE
                    does not list yet, each then added to it; a session's later lines carry only the cost added since
                    its line before (cost_usd) and the pull requests reported before them (cost_shared_with)
  cancel ID         cancels a task you submitted: a queued one, or one in needs_review, at once; a running one is
                    stopped by its runner within seconds and settles cancelled (follow it with wait). Prints the
                    attempt and its status after";
/// What `attach` tells the session it wakes.
const ATTACH_PROMPT: &str = "The owner opened this session in its pane to work with you: say in one line where you \
are, then wait for their input.";
const ATTACH_TIMEOUT: Duration = Duration::from_secs(600);
/// Flags that take no value.
const SWITCHES: [&str; 2] = ["follow", "merged"];
/// Flags that may be given more than once, each value kept.
const REPEATED: [&str; 1] = ["requires"];
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
    repeated: BTreeMap<String, Vec<String>>,
    positional: Vec<String>,
}

impl Args {
    fn parse(rest: &[String]) -> Result<Self, Fail> {
        let mut args = Self {
            flags: BTreeMap::new(),
            repeated: BTreeMap::new(),
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
            if REPEATED.contains(&key) {
                args.repeated
                    .entry(key.to_owned())
                    .or_default()
                    .push(value.clone());
            } else if args.flags.insert(key.to_owned(), value.clone()).is_some() {
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

    fn all(&self, key: &str) -> &[String] {
        self.repeated.get(key).map_or(&[], Vec::as_slice)
    }

    /// Refuses a flag `cmd` does not take, so a misspelt `--modle` is not silently dropped.
    fn only(&self, cmd: &str, known: &[&str], positional: usize) -> Result<(), Fail> {
        if let Some(k) = self
            .flags
            .keys()
            .chain(self.repeated.keys())
            .find(|k| !known.contains(&k.as_str()))
        {
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
            "requires",
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
    let requires: BTreeSet<String> = args.all("requires").iter().cloned().collect();
    if let Some(bad) = requires.iter().find(|r| !capability_name(r)) {
        return Err(Fail::Usage(format!(
            "--requires {bad:?} is not a capability name (a-z, 0-9 and -, from a letter, at most 32)"
        )));
    }
    if requires.len() > MAX_REQUIRES {
        return Err(Fail::Usage(format!("at most {MAX_REQUIRES} --requires")));
    }
    let key = args.opt("key").map_or_else(
        || {
            // a task with no requirement keeps the key it had before --requires
            let what = if requires.is_empty() {
                json!([agent, repo, rev, workdir, prompt, model])
            } else {
                json!([agent, repo, rev, workdir, prompt, model, requires])
            };
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
        capabilities: requires,
        resource_class: "small".to_owned(),
        credential_class: "slot".to_owned(),
        // an agent's effects are not known to be safe to replay
        retry: RetryPolicy { max_attempts: 1 },
        pins: Pins::default(),
    };
    task.validate(&task.capabilities)
        .map_err(|e| Fail::Usage(e.to_string()))?;
    exec_pool::agent::argv(&task).map_err(|e| Fail::Usage(e.to_string()))?;
    Ok(task)
}

/// What `submit_task` takes (`0028_requires.up.sql`): at most 8 names of `[a-z][a-z0-9-]{0,31}`.
const MAX_REQUIRES: usize = 8;

fn capability_name(name: &str) -> bool {
    name.len() <= 32
        && name.starts_with(|c: char| c.is_ascii_lowercase())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
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
            let repos = std::env::var("EXEC_POOL_REPOS").unwrap_or_else(|_| REPOS.to_owned());
            match std::fs::read_to_string(&repos) {
                Ok(list) => listed(&task.source.repo, &list).map_err(Fail::Usage)?,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(Fail::Usage(format!("{repos}: {e}"))),
            }
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
            args.only("sessions", &["limit", "merged", "report"], 1)?;
            sessions(store, args)?;
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

/// `sessions`: the queue's summaries, each with its pull request, filtered and recorded as its flags ask.
fn sessions(store: &mut Store, args: &Args) -> Result<(), Fail> {
    let limit = args.opt("limit").map_or(Ok(20), |n| {
        n.parse::<i64>()
            .ok()
            .filter(|n| *n > 0)
            .ok_or_else(|| Fail::Usage("--limit must be a positive number".to_owned()))
    })?;
    let report = args.opt("report").map(std::path::Path::new);
    let reported = match report {
        None => BTreeMap::new(),
        Some(f) => match std::fs::read_to_string(f) {
            Ok(s) => read_reported(&s),
            Err(e) if e.kind() == io::ErrorKind::NotFound => BTreeMap::new(),
            Err(e) => return Err(Fail::Usage(format!("--report {}: {e}", f.display()))),
        },
    };
    for summary in store.session_summaries(args.positional.first().map(String::as_str), limit)? {
        let Some(f) = report else {
            let summary = with_pull(summary);
            if args.opt("merged").is_some() && !merged(&summary) {
                continue;
            }
            println!("{summary}");
            continue;
        };
        if !out_of_the_pool(&summary) {
            continue;
        }
        // a reported session is asked again: it may since have merged another pull request from its branch
        let Ok(pulls) = pulls(&summary) else {
            continue;
        };
        let task = summary
            .get("task")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        for (line, records) in report_lines(&summary, &pulls, reported.get(&task)) {
            use std::io::Write as _;
            println!("{line}");
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(f)
                .and_then(|mut f| records.iter().try_for_each(|r| writeln!(f, "{r}")))
                .map_err(|e| Fail::Usage(format!("--report {}: {e}", f.display())))?;
        }
    }
    Ok(())
}

/// What a report file records of one session: a bare `task` line (all a binary from before per-PR lines wrote), and
/// a `task NUMBER COST` line per pull request reported, COST the `cost_usd` its line logged (`-` for none).
#[derive(Debug, Default, PartialEq)]
struct Reported {
    bare: bool,
    prs: BTreeSet<u64>,
    cost_usd: f64,
    unpriced: bool,
}

fn read_reported(text: &str) -> BTreeMap<String, Reported> {
    let mut all: BTreeMap<String, Reported> = BTreeMap::new();
    for line in text.lines() {
        let mut words = line.split_whitespace();
        let Some(task) = words.next() else { continue };
        let r = all.entry(task.to_owned()).or_default();
        match (words.next().and_then(|n| n.parse().ok()), words.next()) {
            (Some(n), Some(cost)) => {
                r.prs.insert(n);
                match cost.parse::<f64>() {
                    Ok(c) => r.cost_usd += c,
                    Err(_) => r.unpriced = true,
                }
            }
            _ => r.bare = true,
        }
    }
    all
}

/// The report's lines for a session out of the pool, one per merged pull request of `pulls` (its branch's, oldest
/// first) that `prior` has not recorded, each with the records to append for it. The first line of a session is
/// today's summary with `pr` and `rescued`.
fn report_lines(
    summary: &Value,
    pulls: &[Value],
    prior: Option<&Reported>,
) -> Vec<(Value, Vec<String>)> {
    let task = summary["task"].as_str().unwrap_or_default();
    let newest = pulls.last().map(|p| &p["number"]);
    let mut merged_prs = pulls.iter().filter(|p| p["state"] == "merged");
    let mut earlier: Vec<u64> = prior
        .map(|r| r.prs.iter().copied().collect())
        .unwrap_or_default();
    // a bare line alone is from a binary before per-PR lines: taken as the oldest merged one, its cost not kept
    let legacy = prior.is_some_and(|r| r.bare && r.prs.is_empty());
    let mut assumed = None;
    if legacy {
        assumed = merged_prs.next().and_then(|p| p["number"].as_u64());
        earlier.extend(assumed);
    }
    let mut logged = prior.map_or(0.0, |r| r.cost_usd);
    let mut unpriced = legacy || prior.is_some_and(|r| r.unpriced);
    let mut lines = Vec::new();
    for pr in merged_prs {
        let Some(number) = pr["number"].as_u64() else {
            continue;
        };
        if earlier.contains(&number) {
            continue;
        }
        let mut line = summary.clone();
        let rescued = if Some(&pr["number"]) == newest {
            rescued(pr, summary.get("head").unwrap_or(&Value::Null))
        } else {
            Value::Null
        };
        let mut records = Vec::new();
        if let Some(fields) = line.as_object_mut() {
            fields.insert("pr".to_owned(), pr.clone());
            fields.insert("rescued".to_owned(), rescued);
            // cost: a session's first line carries all of it so far, each later one only what was added since
            if !earlier.is_empty() {
                let cost = fields.get("cost_usd").and_then(Value::as_f64);
                match cost {
                    Some(c) if !unpriced => {
                        let added = ((c - logged) * 1e6).round().max(0.0) / 1e6;
                        fields.insert("cost_usd".to_owned(), json!(added));
                    }
                    Some(_) => {
                        fields.remove("cost_usd");
                    }
                    None => {}
                }
                fields.insert("cost_shared_with".to_owned(), json!(earlier));
            }
        }
        if prior.is_none() && earlier.is_empty() {
            records.push(task.to_owned());
        }
        if let Some(n) = assumed.take() {
            records.push(format!("{task} {n} -"));
        }
        if let Some(c) = line.get("cost_usd").and_then(Value::as_f64) {
            logged += c;
            records.push(format!("{task} {number} {c}"));
        } else {
            unpriced = true;
            records.push(format!("{task} {number} -"));
        }
        earlier.push(number);
        lines.push((line, records));
    }
    lines
}

/// Whether a session's summary shows it neither in a slot nor queued for one: what it cost is what it will have
/// cost unless it is woken again.
fn out_of_the_pool(summary: &Value) -> bool {
    !matches!(
        summary["state"].as_str(),
        Some("queued" | "leased" | "running" | "checkpointing") | None
    )
}

fn merged(summary: &Value) -> bool {
    summary.pointer("/pr/state").and_then(Value::as_str) == Some("merged")
}

/// `(owner, name)` of a GitHub repository as `submit --repo` names it; `None` for any other host or shape.
fn github_repo(url: &str) -> Option<(&str, &str)> {
    let path = [
        "https://github.com/",
        "ssh://git@github.com/",
        "git@github.com:",
    ]
    .iter()
    .find_map(|p| url.strip_prefix(p))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    let ok = |s: &str| {
        !s.is_empty()
            && !s.starts_with('.')
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    (ok(owner) && ok(name)).then_some((owner, name))
}

/// Whether the slot proxy lets a task reach `repo`: a GitHub repository named in `list`, as its regex matches (case
/// aside). Refused here, a start is not left to fail at prepare, where git cannot read through the proxy.
fn listed(repo: &str, list: &str) -> Result<(), String> {
    let refused = || {
        format!(
            "--repo {repo:?} is not in the execution pool's repository list (homelab.execPool.repos, {REPOS}): add it there and deploy the pool's hosts"
        )
    };
    let (owner, name) = github_repo(repo).ok_or_else(refused)?;
    let want = format!("{owner}/{name}");
    list.lines()
        .map(str::trim)
        .any(|l| l.eq_ignore_ascii_case(&want))
        .then_some(())
        .ok_or_else(refused)
}

/// The pull requests of a GitHub `pulls?head=…&state=all` listing, oldest first: each one's number, state (merged
/// once it has a merge time), merge time and head commit.
fn pulls_of(listing: &Value) -> Result<Vec<Value>, String> {
    let mut pulls: Vec<&Value> = listing
        .as_array()
        .ok_or_else(|| format!("GitHub answered {listing}"))?
        .iter()
        .collect();
    pulls.sort_by_key(|p| p["number"].as_u64());
    Ok(pulls
        .into_iter()
        .map(|p| {
            let merged_at = &p["merged_at"];
            json!({
                "number": p["number"],
                "state": if merged_at.is_string() { "merged" } else { p["state"].as_str().unwrap_or("unknown") },
                "merged_at": merged_at,
                "url": p["html_url"],
                "head": p.pointer("/head/sha").cloned().unwrap_or(Value::Null),
            })
        })
        .collect())
}

/// The pull requests of a summary's branch `pool/<task>` as `gh api` on this host finds them, oldest first; the error
/// says why they could not be told: no GitHub repository, no gh, or a refused call.
fn pulls(summary: &Value) -> Result<Vec<Value>, String> {
    let task = summary
        .get("task")
        .and_then(Value::as_str)
        .unwrap_or_default();
    // never the branch the session reported: one naming another's would take that pull request
    let branch = format!("pool/{task}");
    summary
        .get("repo")
        .and_then(Value::as_str)
        .and_then(github_repo)
        .ok_or_else(|| "not a GitHub repository".to_owned())
        .and_then(|(owner, name)| {
            let out = std::process::Command::new("gh")
                .args(["api", "-X", "GET", &format!("repos/{owner}/{name}/pulls")])
                .args(["-f", &format!("head={owner}:{branch}"), "-f", "state=all"])
                .stdin(std::process::Stdio::null())
                .output()
                .map_err(|e| format!("gh: {e}"))?;
            if !out.status.success() {
                let err = String::from_utf8_lossy(&out.stderr);
                return Err(format!("gh api: {}", err.trim()));
            }
            serde_json::from_slice(&out.stdout)
                .map_err(|e| format!("gh api: {e}"))
                .and_then(|v| pulls_of(&v))
        })
}

/// `summary` with `pr`, its branch's newest pull request, and `pr_error` when [`pulls`] could not tell.
fn with_pull(mut summary: Value) -> Value {
    let found = pulls(&summary).map(|mut p| p.pop().unwrap_or(Value::Null));
    if let Some(fields) = summary.as_object_mut() {
        match found {
            Ok(pr) => {
                let rescued = rescued(&pr, fields.get("head").unwrap_or(&Value::Null));
                fields.insert("pr".to_owned(), pr);
                fields.insert("rescued".to_owned(), rescued);
            }
            Err(e) => {
                fields.insert("pr".to_owned(), Value::Null);
                fields.insert("pr_error".to_owned(), Value::String(e));
            }
        }
    }
    summary
}

/// Whether a merged pull request was finished by someone else than the task: its head is not the commit the task
/// pushed. Null unless it merged and the runner recorded that commit.
fn rescued(pr: &Value, pushed: &Value) -> Value {
    match (pr["state"].as_str(), pr["head"].as_str(), pushed.as_str()) {
        (Some("merged"), Some(merged), Some(pushed)) => Value::Bool(merged != pushed),
        _ => Value::Null,
    }
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
    fn each_requires_is_a_capability_of_the_task_and_part_of_its_key() {
        let t = spec(&with(&["--requires", "monitoring", "--requires", "github"])).unwrap();
        assert_eq!(
            t.capabilities,
            BTreeSet::from(["github".to_owned(), "monitoring".to_owned()])
        );
        let plain = spec(&BASE).unwrap();
        assert_ne!(t.idempotency_key, plain.idempotency_key);
        assert_eq!(
            spec(&with(&["--requires", "github", "--requires", "monitoring"]))
                .unwrap()
                .idempotency_key,
            t.idempotency_key
        );
        let session = task_spec("start", &args(&with(&["--requires", "always-on"]))).ok();
        assert_eq!(
            session.map(|s| s.capabilities),
            Some(BTreeSet::from(["always-on".to_owned()]))
        );
        for bad in ["GitHub", "read_only", "-x", ""] {
            let got = spec(&with(&["--requires", bad])).unwrap_err();
            assert!(got.contains("not a capability name"), "{bad:?}: {got}");
        }
        let many: Vec<&str> = BASE
            .iter()
            .copied()
            .chain(
                ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
                    .iter()
                    .flat_map(|n| ["--requires", *n]),
            )
            .collect();
        assert!(spec(&many).unwrap_err().contains("at most 8"));
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
    fn a_repository_off_the_pool_s_list_is_refused_naming_the_list() {
        let list = "sammasak/nixos-config\r\n  sammasak/Pi-Harness\n";
        for url in [
            "https://github.com/sammasak/nixos-config.git",
            "ssh://git@github.com/sammasak/nixos-config/",
            "git@github.com:sammasak/pi-harness.git",
        ] {
            assert_eq!(listed(url, list), Ok(()), "{url}");
        }
        for url in [
            "https://github.com/sammasak/paddock.git",
            "https://github.com/other/nixos-config",
            "/srv/git/nixos-config",
        ] {
            let got = listed(url, list).unwrap_err();
            assert!(got.contains("homelab.execPool.repos"), "{url}: {got}");
        }
    }

    /// The newest pull request of a listing, as `with_pull` takes it.
    fn pull_of(listing: &Value) -> Result<Value, String> {
        Ok(pulls_of(listing)?.pop().unwrap_or(Value::Null))
    }

    #[test]
    fn a_session_s_repository_and_pull_request_are_read_from_what_github_lists() {
        for url in [
            "https://github.com/sammasak/nixos-config.git",
            "https://github.com/sammasak/nixos-config",
            "git@github.com:sammasak/nixos-config.git",
            "ssh://git@github.com/sammasak/nixos-config/",
        ] {
            assert_eq!(
                github_repo(url),
                Some(("sammasak", "nixos-config")),
                "{url}"
            );
        }
        for url in [
            "https://gitlab.com/sammasak/nixos-config",
            "https://github.com/sammasak",
            "https://github.com/sammasak/a/b",
            "https://github.com/../x",
            "https://github.com/sammasak/x?y",
            "/srv/git/nixos-config",
        ] {
            assert_eq!(github_repo(url), None, "{url}");
        }
        let listed = json!([
            {"number": 788, "state": "closed", "merged_at": "2026-11-25T06:40:00Z", "html_url": "https://github.com/o/r/pull/788", "head": {"sha": "1f2e"}},
            {"number": 780, "state": "closed", "merged_at": null, "html_url": "https://github.com/o/r/pull/780"}
        ]);
        assert_eq!(
            pull_of(&listed).unwrap(),
            json!({"number": 788, "state": "merged", "merged_at": "2026-11-25T06:40:00Z", "url": "https://github.com/o/r/pull/788", "head": "1f2e"})
        );
        let pr = pull_of(&listed).unwrap();
        assert_eq!(
            rescued(&pr, &json!("1f2e")),
            json!(false),
            "the task's own commit merged"
        );
        assert_eq!(
            rescued(&pr, &json!("0a0a")),
            json!(true),
            "another commit merged"
        );
        assert_eq!(rescued(&pr, &Value::Null), Value::Null, "no head recorded");
        let open = pull_of(&json!([listed[1]])).unwrap();
        assert_eq!(rescued(&open, &json!("1f2e")), Value::Null, "not merged");
        assert_eq!(pull_of(&json!([listed[1]])).unwrap()["state"], "closed");
        assert_eq!(pull_of(&json!([])).unwrap(), Value::Null);
        assert!(pull_of(&json!({"message": "Not Found"})).is_err());
    }

    #[test]
    fn the_report_takes_a_merged_session_once_it_is_out_of_the_pool() {
        let at = |state: &str, pr: Value| json!({"task": "cli-1", "state": state, "pr": pr});
        let merged_pr = json!({"number": 1, "state": "merged"});
        for state in [
            "waiting",
            "needs_review",
            "succeeded",
            "failed",
            "cancelled",
        ] {
            let s = at(state, merged_pr.clone());
            assert!(out_of_the_pool(&s) && merged(&s), "{state}");
        }
        for state in ["queued", "leased", "running", "checkpointing"] {
            assert!(!out_of_the_pool(&at(state, merged_pr.clone())), "{state}");
        }
        assert!(!merged(&at(
            "waiting",
            json!({"number": 1, "state": "open"})
        )));
        assert!(!merged(&at("waiting", Value::Null)));
    }

    /// The report run as `sessions --report` runs it, on `file`'s text: the lines it logs and the text after.
    fn report(file: &str, summary: &Value, pulls: &[Value]) -> (Vec<Value>, String) {
        let reported = read_reported(file);
        let task = summary["task"].as_str().unwrap();
        let mut text = file.to_owned();
        let lines = report_lines(summary, pulls, reported.get(task))
            .into_iter()
            .map(|(line, records)| {
                for r in records {
                    text.push_str(&r);
                    text.push('\n');
                }
                line
            })
            .collect();
        (lines, text)
    }

    fn merged_pull(number: u64, head: &str) -> Value {
        json!({"number": number, "state": "merged", "merged_at": "2026-11-26T00:31:00Z", "url": "u", "head": head})
    }

    fn total(lines: &[Value]) -> f64 {
        lines.iter().filter_map(|l| l["cost_usd"].as_f64()).sum()
    }

    #[test]
    fn a_one_pr_session_logs_today_s_line_once() {
        let summary = json!({"task": "cli-1", "state": "waiting", "cost_usd": 2.0, "head": "aa"});
        let pr = merged_pull(839, "aa");
        let (lines, file) = report("", &summary, std::slice::from_ref(&pr));
        let mut want = summary.clone();
        want["pr"] = pr.clone();
        want["rescued"] = json!(false);
        assert_eq!(lines, [want]);
        assert_eq!(file, "cli-1\ncli-1 839 2\n");
        let (again, same) = report(&file, &summary, &[pr]);
        assert!(again.is_empty(), "{again:?}");
        assert_eq!(same, file);
    }

    #[test]
    fn a_session_s_second_merged_pr_logs_a_line_counting_its_cost_once() {
        let summary = json!({"task": "cli-7", "state": "waiting", "cost_usd": 4.51, "head": "bb"});
        let pulls = [
            merged_pull(839, "aa"),
            json!({"number": 840, "state": "closed", "merged_at": null}),
            merged_pull(847, "bb"),
        ];
        let (lines, file) = report("", &summary, &pulls);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["pr"]["number"], 839);
        assert_eq!(lines[0]["cost_usd"], 4.51);
        assert_eq!(lines[0]["rescued"], Value::Null, "not the branch's newest");
        assert_eq!(lines[0].get("cost_shared_with"), None);
        assert_eq!(lines[1]["pr"]["number"], 847);
        assert_eq!(lines[1]["cost_shared_with"], json!([839]));
        assert_eq!(lines[1]["rescued"], json!(false));
        assert!((total(&lines) - 4.51).abs() < 1e-9);
        let (again, _) = report(&file, &summary, &pulls);
        assert!(again.is_empty(), "{again:?}");

        let later = json!({"task": "cli-7", "state": "waiting", "cost_usd": 6.01, "head": "cc"});
        let mut more = pulls.to_vec();
        more.push(merged_pull(861, "cc"));
        let (third, file) = report(&file, &later, &more);
        assert_eq!(third.len(), 1);
        assert_eq!(third[0]["pr"]["number"], 861);
        assert_eq!(third[0]["cost_usd"], 1.5, "only what it added since");
        assert_eq!(third[0]["cost_shared_with"], json!([839, 847]));
        assert!(report(&file, &later, &more).0.is_empty());
    }

    #[test]
    fn a_session_reported_before_per_pr_lines_logs_its_next_pr_unpriced() {
        let summary = json!({"task": "cli-7", "state": "waiting", "cost_usd": 4.51, "head": "bb"});
        let pulls = [merged_pull(839, "aa"), merged_pull(847, "bb")];
        let (lines, file) = report("cli-7\n", &summary, &pulls);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0]["pr"]["number"], 847);
        assert_eq!(
            lines[0].get("cost_usd"),
            None,
            "its first line's cost went unrecorded"
        );
        assert_eq!(lines[0]["cost_shared_with"], json!([839]));
        assert_eq!(file, "cli-7\ncli-7 839 -\ncli-7 847 -\n");
        assert!(report(&file, &summary, &pulls).0.is_empty());
    }

    #[test]
    fn an_unpriced_one_shot_s_pull_requests_stay_unpriced() {
        let summary = json!({"task": "cli-9", "state": "succeeded", "cost_usd": null});
        let pulls = [merged_pull(5, "aa"), merged_pull(6, "bb")];
        let (lines, file) = report("", &summary, &pulls);
        assert_eq!(lines.len(), 2);
        assert!(lines.iter().all(|l| l["cost_usd"].is_null()));
        assert_eq!(file, "cli-9\ncli-9 5 -\ncli-9 6 -\n");
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
