//! Turns a task into the command a runner executes in a slot, and that command's exit into the attempt's outcome.
//!
//! An agent task's `command.argv` is `[prompt]` or `[prompt, model]`; a brief is a prompt naming a file in the
//! checkout. The agent gets the prompt behind [`PREFIX`]'s rules for handing code back on its [`branch`]. It runs with
//! the slot's own credentials and egress; nothing here adds any.
//!
//! A session task runs one turn per lease in its own tree, under the session id the queue gave it, as interactive
//! Claude in the slot's Herdr pane: [`session_argv`] starts that session on the turn that finds no transcript of it
//! ([`transcript_probe`]), and resumes it on every other, so a turn that died before its first write starts it again
//! rather than resuming nothing.

use serde::Deserialize;

use crate::{Agent, Outcome, TaskSpec};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("an {0:?} task's argv is [prompt] or [prompt, model], with a non-empty prompt")]
    Argv(Agent),
    #[error("model {0:?} must be non-empty and not start with `-`")]
    Model(String),
    #[error(
        "task id {0:?} does not make a branch name: up to 100 of [A-Za-z0-9_-], not starting with `-`"
    )]
    Branch(String),
    #[error("an {0:?} task cannot run as a session yet")]
    NoSession(Agent),
    #[error("session id {0:?} is not a UUID")]
    SessionId(String),
    #[error("a turn's input must not be empty")]
    Input,
}

/// What every agent is told before its prompt; `{branch}` is the task's [`branch`].
pub const PREFIX: &str = "You run as an execution pool task in a throwaway checkout, on branch {branch}. To hand back \
code, commit on {branch} with a message whose body has a `Why:` line and push that branch alone. Where the \
repository has a devenv.nix, commit and push only through its shell, `devenv shell -- git commit ...` and \
`devenv shell -- git push origin {branch}`: entering it installs the hooks, and a plain `git commit` or `git push` \
in a fresh clone runs none. Elsewhere, `git push origin {branch}`. Never push main or any other branch, never \
force-push, never skip a hook (no --no-verify, no SKIP=); if a hook refuses the push, say why in your answer. The task:\n\n";

/// What an agent on a GitHub repository is also told, before "The task:" of [`PREFIX`].
///
/// `gh pr create` and `gh pr comment` go through GraphQL, which the slot's GitHub proxy refuses (it bounds no
/// repository), so it is told the REST calls the proxy passes; `{repo}` is the repository's `owner/name`.
pub const PULL_REQUEST: &str = "To open a pull request from your branch, or comment on one, call GitHub's REST API: \
`gh pr create` and `gh pr comment` use GraphQL, which the pool's GitHub proxy refuses. Open it with \
`gh api repos/{repo}/pulls -f head={branch} -f base=BASE -f title=TITLE -F body=@FILE` and comment with \
`gh api repos/{repo}/issues/NUMBER/comments -F body=@FILE`; no merge, review or other branch. Before you open a \
pull request, check your diff against every item of the task and against what a strict reviewer looks for (privilege, \
PATH and secrets; failure and rollback paths; a test for each behaviour); fix what you find and name in the pull \
request body what is still unmet. That is your own check, not the independent review. ";

/// What a session's first turn is also told, before "The task:" of [`PREFIX`]: how to wait for an outside event, and
/// what a pause keeps.
pub const SESSION_WAIT: &str = "To wait for an outside event, run `pool-wait --until HH:MM|RFC3339 [--note TEXT]`: \
the session is woken then, told the note. End your turn right after calling it. When you stop and wait for input (a \
review, a gate, the owner), this session pauses: after a while it parks and resumes on its next message, perhaps in \
another slot on another host. What survives a pause: the transcript, the session home and the work tree with \
uncommitted changes. What does not: running processes in the slot (dev servers, background shells, a build in \
flight). Before you stop or wait, commit and push your work to your branch; do not rely on a background process \
across a wait. While you wait, send no status messages: report only a result or a blocker. ";

/// What a session turn is told about its park, on its first turn before "The task:" and after every later turn's
/// input: what of its slot survives the turn.
pub const SESSION_PARK: &str = "Before you end a turn or wait, commit your work and push your branch as above: the next turn may run on another host from a fresh clone of it. The pool keeps what is left uncommitted as a snapshot and the session's transcript, nothing else of the checkout or home: no ignored files, build outputs or running processes. ";

/// [`PREFIX`] for `task`, with [`PULL_REQUEST`] before its last sentence when its repository is on GitHub.
///
/// # Errors
/// What [`branch`] rejects.
pub fn prefix(task: &TaskSpec) -> Result<String, Error> {
    let name = branch(task)?;
    let slug = crate::runner::github_push_url(&task.source.repo).and_then(|u| {
        u.strip_prefix("git@github.com:")
            .and_then(|r| r.strip_suffix(".git"))
            .map(str::to_owned)
    });
    let out = PREFIX.replace("{branch}", &name);
    Ok(match slug {
        Some(slug) => out.replace(
            "The task:",
            &format!(
                "{}The task:",
                PULL_REQUEST
                    .replace("{repo}", &slug)
                    .replace("{branch}", &name)
            ),
        ),
        None => out,
    })
}

/// The prefix of a session's first turn: [`prefix`] with [`SESSION_WAIT`] and [`SESSION_PARK`] before its last
/// sentence.
fn session_prefix(task: &TaskSpec) -> Result<String, Error> {
    Ok(prefix(task)?.replace(
        "The task:",
        &format!("{SESSION_WAIT}{SESSION_PARK}The task:"),
    ))
}

/// The branch an attempt of `task` works and pushes on: `pool/<task id>`.
///
/// # Errors
/// [`Error::Branch`] for an id that is empty, longer than 100 bytes, starts with `-` or holds anything but ASCII
/// letters, digits, `_` and `-`, so the name is a valid ref and no option.
pub fn branch(task: &TaskSpec) -> Result<String, Error> {
    let id = &task.id;
    let ok = !id.is_empty()
        && id.len() <= 100
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    if ok {
        Ok(format!("pool/{id}"))
    } else {
        Err(Error::Branch(id.clone()))
    }
}

/// The argv to execute in the task's workdir: a `none` task's own argv, or the agent's non-interactive call.
///
/// # Errors
/// An agent task whose argv is not `[prompt]` or `[prompt, model]`, or whose model would read as a flag.
pub fn argv(task: &TaskSpec) -> Result<Vec<String>, Error> {
    let (mut out, prompt) = call(task)?;
    let Some(prompt) = prompt else {
        return Ok(out);
    };
    let prefix = prefix(task)?;
    // `--` so a prompt starting with `-` is not read as a flag
    out.extend(["--".to_owned(), format!("{prefix}{prompt}")]);
    Ok(out)
}

/// How a session turn's agent call takes its session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Turn {
    /// No transcript of the session yet: start it under its id, [`PREFIX`] (with [`SESSION_WAIT`]) before the input,
    /// as the agent has not seen it (a first turn, or one after a turn that died before its first write).
    Start,
    /// A transcript exists: resume it.
    Resume,
}

/// The socket of a session turn's agent terminal, in its HOME: the slot's Herdr pane attaches to it.
pub const AGENT_SOCKET: &str = "/session/cur/home/.exec-pool-agent.sock";

/// A session turn's agent: interactive Claude in a terminal the slot's Herdr pane attaches to.
///
/// It runs under `dtach -N` [`AGENT_SOCKET`], with `--session-id` or `--resume` of `session` (the queue's UUID) and
/// the task's model.
/// Claude is called as the named workers called it, through the login shell's `claude` function (Herdr's launcher,
/// which adds the worker settings) with `--dangerously-skip-permissions`; Herdr's auto-attach is off, as the guest
/// runs no Herdr. `dtach` and `env` are store paths. The turn's input is no argument: it is prompted in the pane
/// ([`turn_input`]).
///
/// # Errors
/// What [`argv`] rejects of the task, [`Error::NoSession`] for any agent but Claude, or [`Error::SessionId`] for an
/// id that is not a UUID.
pub fn session_argv(
    task: &TaskSpec,
    session: &str,
    turn: Turn,
    (dtach, env): (&str, &str),
) -> Result<Vec<String>, Error> {
    if task.command.agent != Agent::Claude {
        return Err(Error::NoSession(task.command.agent));
    }
    if !is_uuid(session) {
        return Err(Error::SessionId(session.to_owned()));
    }
    let (call, _) = call(task)?;
    let mut out: Vec<String> = [
        dtach,
        "-N",
        AGENT_SOCKET,
        env,
        "TERM=xterm-256color",
        "HERDR_AUTOATTACH_DISABLED=1",
        "fish",
        "-c",
        "claude $argv",
        "--",
        "--dangerously-skip-permissions",
    ]
    .map(str::to_owned)
    .to_vec();
    // the base call's model, without its print-mode flags
    out.extend(call.into_iter().skip_while(|a| a != "--model"));
    let flag = match turn {
        Turn::Start => "--session-id",
        Turn::Resume => "--resume",
    };
    out.extend([flag.to_owned(), session.to_owned()]);
    Ok(out)
}

/// A headless session turn's agent call, on a host whose runner has no pane for it.
///
/// Claude's print mode with `--session-id` or `--resume` of `session` and [`turn_input`] as its prompt, the task's
/// model kept.
///
/// # Errors
/// What [`session_argv`] and [`turn_input`] reject.
pub fn headless_argv(
    task: &TaskSpec,
    session: &str,
    input: &str,
    turn: Turn,
) -> Result<Vec<String>, Error> {
    if task.command.agent != Agent::Claude {
        return Err(Error::NoSession(task.command.agent));
    }
    if !is_uuid(session) {
        return Err(Error::SessionId(session.to_owned()));
    }
    let prompt = turn_input(task, input, turn)?;
    let (mut out, _) = call(task)?;
    let flag = match turn {
        Turn::Start => "--session-id",
        Turn::Resume => "--resume",
    };
    out.extend([flag.to_owned(), session.to_owned(), "--".to_owned(), prompt]);
    Ok(out)
}

/// What a session turn tells its agent: [`PREFIX`] (with [`SESSION_WAIT`]) before `input` when it starts the
/// session, `input` alone when it resumes it.
///
/// # Errors
/// [`Error::Input`] for an empty input, or what [`branch`] rejects.
pub fn turn_input(task: &TaskSpec, input: &str, turn: Turn) -> Result<String, Error> {
    if input.is_empty() {
        return Err(Error::Input);
    }
    Ok(match turn {
        Turn::Start => format!("{}{input}", session_prefix(task)?),
        Turn::Resume => input.to_owned(),
    })
}

/// The guest command whose output names the session's transcript under `home` if Claude has written one.
///
/// It is empty if not: `find` (a store path) over `.claude/projects/*/<session>.jsonl`, following no symlink.
#[must_use]
pub fn transcript_probe(find: &str, home: &str, session: &str) -> Vec<String> {
    [
        find,
        &format!("{home}/.claude/projects"),
        "-mindepth",
        "2",
        "-maxdepth",
        "2",
        "-type",
        "f",
        "-name",
        &format!("{session}.jsonl"),
        "-print",
        "-quit",
    ]
    .map(str::to_owned)
    .to_vec()
}

/// Whether `s` is a UUID in its hyphenated hex form, any version.
fn is_uuid(s: &str) -> bool {
    let groups: Vec<&str> = s.split('-').collect();
    groups.iter().map(|g| g.len()).eq([8, 4, 4, 4, 12])
        && groups
            .iter()
            .all(|g| g.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// The agent's base call with its model, and the prompt the task gave it; a `none` task's own argv and no prompt.
fn call(task: &TaskSpec) -> Result<(Vec<String>, Option<&String>), Error> {
    let agent = task.command.agent;
    let base: &[&str] = match agent {
        Agent::None => return Ok((task.command.argv.clone(), None)),
        Agent::Claude => &[
            "claude",
            "-p",
            "--output-format",
            "json",
            "--dangerously-skip-permissions",
        ],
        Agent::Codex => &[
            "codex",
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--dangerously-bypass-hook-trust",
        ],
        Agent::Pi => &["pi", "-p"],
    };
    let (prompt, model) = match task.command.argv.as_slice() {
        [p] => (p, None),
        [p, m] => (p, Some(m)),
        _ => return Err(Error::Argv(agent)),
    };
    if prompt.is_empty() {
        return Err(Error::Argv(agent));
    }
    let mut out: Vec<String> = base.iter().map(|s| (*s).to_owned()).collect();
    if let Some(m) = model {
        if m.is_empty() || m.starts_with('-') {
            return Err(Error::Model(m.clone()));
        }
        out.extend(["--model".to_owned(), m.clone()]);
    }
    Ok((out, Some(prompt)))
}

/// Claude's `--output-format json` result; `subtype` can read `success` while `is_error` is true.
#[derive(Deserialize)]
struct ClaudeResult {
    is_error: bool,
}

/// The attempt's outcome from the command's exit code (`None`: killed by a signal) and its stdout.
///
/// Claude's final JSON line decides for Claude, the exit code for everything else. A signal, or a Claude run that
/// left no result, may have stopped mid-effect: `needs_review`, which only an operator resolves. Neither `failed` nor
/// `needs_review` requeues, so no outcome here replays an external effect.
#[must_use]
pub fn outcome(agent: Agent, exit: Option<i32>, stdout: &str) -> Outcome {
    match (agent, exit) {
        (_, None) => Outcome::NeedsReview,
        (Agent::Claude, Some(_)) => stdout
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .and_then(|l| serde_json::from_str::<ClaudeResult>(l).ok())
            .map_or(Outcome::NeedsReview, |r| {
                if r.is_error {
                    Outcome::Failed
                } else {
                    Outcome::Succeeded
                }
            }),
        (_, Some(0)) => Outcome::Succeeded,
        (_, Some(_)) => Outcome::Failed,
    }
}
