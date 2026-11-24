//! Turns a task into the command a runner executes in a slot, and that command's exit into the attempt's outcome.
//!
//! An agent task's `command.argv` is `[prompt]` or `[prompt, model]`; a brief is a prompt naming a file in the
//! checkout. The agent gets the prompt behind [`PREFIX`]'s rules for handing code back on its [`branch`]. It runs with
//! the slot's own credentials and egress; nothing here adds any.

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
}

/// What every agent is told before its prompt; `{branch}` is the task's [`branch`].
pub const PREFIX: &str = "You run as an execution pool task in a throwaway checkout, on branch {branch}. To hand back \
code, commit on {branch} with a message whose body has a `Why:` line and push that branch alone: \
`git push origin {branch}`, or `devenv shell -- git push origin {branch}` where the repository has a devenv.nix, so \
its pre-push hooks run. Never push main or any other branch, never force-push, never skip a hook (no --no-verify, no \
SKIP=); if a hook refuses the push, say why in your answer. The task:\n\n";

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
    let agent = task.command.agent;
    let base: &[&str] = match agent {
        Agent::None => return Ok(task.command.argv.clone()),
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
    let prefix = PREFIX.replace("{branch}", &branch(task)?);
    // `--` so a prompt starting with `-` is not read as a flag
    out.extend(["--".to_owned(), format!("{prefix}{prompt}")]);
    Ok(out)
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
