//! What a settled attempt hands back to its submitter.
//!
//! The adapter's verdict, the exit code and at most [`OUTPUT_BYTES`] of output. The runner records it with [`crate::queue::Store::record_result`]; the run directory
//! on the host keeps the whole capture.

use serde::{Deserialize, Serialize};

use crate::runner::{ExecResult, Stage};
use crate::{Agent, Outcome, agent};

/// The `results.output` bound in migration 0003.
pub const OUTPUT_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskResult {
    /// [`agent::outcome`] of the run; `None` when the task's argv never started or the helper left no result.
    pub outcome: Option<Outcome>,
    pub exit_code: Option<i32>,
    /// Claude's `result` text, from its start; for any other agent, or a Claude run with none, the end of stdout
    /// (of its first `CAPTURE_BYTES`: the runner keeps the head of the capture). No NUL, which `text` cannot hold.
    output: String,
    /// The task's branch, `pool/<task id>`, when its repository showed it after the run: the code it handed back.
    pub branch: Option<String>,
    /// What the agent reported the run cost, from Claude's result JSON; `None` for any other agent or none reported.
    #[serde(default)]
    pub usage: Option<Usage>,
    /// `branch` holds everything the run's checkout had, nothing left for a snapshot: `None` when the runner cannot
    /// tell.
    #[serde(default)]
    pub handed_back: Option<bool>,
}

/// A run's tokens and cost as Claude reports them; no content.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_creation_tokens: u64,
    /// `None`: not reported, which is not free.
    pub cost_usd: Option<f64>,
}

#[derive(Deserialize)]
struct ClaudeText {
    result: String,
    #[serde(default)]
    usage: Option<ClaudeUsage>,
    #[serde(default)]
    total_cost_usd: Option<f64>,
}

#[derive(Deserialize)]
#[expect(clippy::struct_field_names, reason = "Claude's result JSON names them")]
struct ClaudeUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

impl TaskResult {
    /// A result whose output is the end of `output`, bounded and with any NUL dropped.
    #[must_use]
    pub fn new(outcome: Option<Outcome>, exit_code: Option<i32>, output: &str) -> Self {
        Self {
            outcome,
            exit_code,
            output: end(&output.replace('\0', "")),
            branch: None,
            usage: None,
            handed_back: None,
        }
    }

    #[must_use]
    pub fn output(&self) -> &str {
        &self.output
    }

    /// The result of a run from the helper's `result` and the attempt's captured `stdout`.
    #[must_use]
    pub fn of(agent: Agent, result: Option<&ExecResult>, stdout: &str) -> Self {
        // a run stopped for a cancel has no verdict, whatever its exit
        let ran = result.filter(|r| r.stage == Stage::Run && !r.cancelled);
        let exit_code = result.and_then(|r| r.exit_code);
        let claude = (agent == Agent::Claude)
            .then(|| stdout.lines().rev().find(|l| !l.trim().is_empty()))
            .flatten()
            .and_then(|l| serde_json::from_str::<ClaudeText>(l).ok());
        let usage = claude.as_ref().and_then(|c| {
            c.usage.as_ref().map(|u| Usage {
                input_tokens: u.input_tokens,
                output_tokens: u.output_tokens,
                cache_read_tokens: u.cache_read_input_tokens,
                cache_creation_tokens: u.cache_creation_input_tokens,
                cost_usd: c.total_cost_usd,
            })
        });
        // a run that failed preparing printed nothing to stdout worth handing back: its step and stderr say why
        let failed = result.and_then(|r| r.failed_step.as_deref().map(|step| (step, r)));
        let output = match (failed, claude) {
            (Some((step, r)), _) => end(&format!(
                "prepare failed at {step} (exit {}):\n{}",
                r.exit_code
                    .map_or_else(|| "none".to_owned(), |c| c.to_string()),
                r.stderr_tail
            )
            .replace('\0', "")),
            (None, Some(c)) => start(&c.result.replace('\0', "")),
            (None, None) => end(&stdout.replace('\0', "")),
        };
        Self {
            outcome: ran.map(|r| agent::outcome(agent, r.exit_code, stdout)),
            exit_code,
            output,
            branch: result.and_then(|r| r.branch.clone()),
            usage,
            handed_back: result.and_then(|r| r.handed_back),
        }
    }
}

/// The first [`OUTPUT_BYTES`] of `s`, cut at a character boundary.
fn start(s: &str) -> String {
    let cut = (0..=OUTPUT_BYTES.min(s.len()))
        .rev()
        .find(|&i| s.is_char_boundary(i))
        .unwrap_or(0);
    s.get(..cut).unwrap_or_default().to_owned()
}

/// The last [`OUTPUT_BYTES`] of `s`, cut at a character boundary.
fn end(s: &str) -> String {
    let cut = (s.len().saturating_sub(OUTPUT_BYTES)..=s.len())
        .find(|&i| s.is_char_boundary(i))
        .unwrap_or(s.len());
    s.get(cut..).unwrap_or_default().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SchemaVersion;

    fn exec(stage: Stage, exit_code: Option<i32>) -> ExecResult {
        ExecResult {
            schema_version: SchemaVersion::CURRENT,
            attempt_id: "t1.a".to_owned(),
            lease_epoch: 1,
            stage,
            exit_code,
            timed_out: false,
            cancelled: false,
            branch: None,
            failed_step: None,
            parked_at: None,
            unkept: None,
            transcript: None,
            handed_back: None,
            wake: None,
            upto: None,
            drained: false,
            container_active: true,
            stdout_tail: String::new(),
            stderr_tail: String::new(),
            prepare_ms: 1,
            run_ms: 1,
        }
    }

    #[test]
    fn claude_hands_back_its_result_text_and_verdict() {
        let stdout = "noise\n{\"is_error\":false,\"result\":\"opened PR #9\"}\n\n";
        let r = TaskResult::of(Agent::Claude, Some(&exec(Stage::Run, Some(0))), stdout);
        assert_eq!(r.outcome, Some(Outcome::Succeeded));
        assert_eq!((r.exit_code, r.output.as_str()), (Some(0), "opened PR #9"));
        assert_eq!(r.usage, None, "no usage reported");
        let reported = r#"{"result":"ok","total_cost_usd":0.25,"usage":{"input_tokens":3,"output_tokens":40,"cache_read_input_tokens":9000,"cache_creation_input_tokens":500}}"#;
        let u = TaskResult::of(Agent::Claude, Some(&exec(Stage::Run, Some(0))), reported);
        assert_eq!(
            u.usage,
            Some(Usage {
                input_tokens: 3,
                output_tokens: 40,
                cache_read_tokens: 9000,
                cache_creation_tokens: 500,
                cost_usd: Some(0.25)
            })
        );
        let none = TaskResult::of(Agent::Claude, Some(&exec(Stage::Run, Some(1))), "crash\n");
        assert_eq!(
            (none.outcome, none.output.as_str()),
            (Some(Outcome::NeedsReview), "crash\n")
        );
    }

    #[test]
    fn output_is_bounded_at_a_character_boundary() {
        let long = "é".repeat(OUTPUT_BYTES);
        let r = TaskResult::of(Agent::Pi, Some(&exec(Stage::Run, Some(2))), &long);
        assert_eq!(r.outcome, Some(Outcome::Failed));
        assert_eq!(r.output.len(), OUTPUT_BYTES);
        assert!(long.ends_with(&r.output));
        let json = serde_json::json!({ "is_error": false, "result": format!("a{long}") });
        let c = TaskResult::of(
            Agent::Claude,
            Some(&exec(Stage::Run, Some(0))),
            &json.to_string(),
        );
        assert_eq!(c.output.len(), OUTPUT_BYTES - 1, "a split 'é' is left out");
        assert!(c.output.starts_with("aé"));
        let nul = TaskResult::new(None, Some(0), &format!("a\0b{long}"));
        assert_eq!(nul.output(), r.output, "bounded");
        assert_eq!(TaskResult::new(None, None, "a\0b").output(), "ab");
    }

    #[test]
    fn a_cancelled_run_has_no_verdict() {
        let stopped = ExecResult {
            cancelled: true,
            ..exec(Stage::Run, Some(0))
        };
        let r = TaskResult::of(Agent::None, Some(&stopped), "out");
        assert_eq!((r.outcome, r.exit_code), (None, Some(0)));
    }

    #[test]
    fn a_failed_prepare_hands_back_its_step_and_stderr() {
        let failed = ExecResult {
            failed_step: Some("exec-pool-clone".to_owned()),
            stderr_tail: "fatal: could not read Username\n".to_owned(),
            ..exec(Stage::Prepare, Some(128))
        };
        let r = TaskResult::of(Agent::Claude, Some(&failed), "");
        assert_eq!(r.outcome, None);
        assert_eq!(
            r.output(),
            "prepare failed at exec-pool-clone (exit 128):\nfatal: could not read Username\n"
        );
    }

    #[test]
    fn a_task_that_never_ran_has_no_verdict() {
        let r = TaskResult::of(Agent::Codex, Some(&exec(Stage::Prepare, Some(128))), "");
        assert_eq!((r.outcome, r.exit_code), (None, Some(128)));
        assert_eq!(TaskResult::of(Agent::Codex, None, "x").outcome, None);
    }
}
