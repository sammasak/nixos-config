use std::collections::BTreeSet;

use exec_pool::agent::{Error, argv, outcome};
use exec_pool::{Agent, Outcome, TaskSpec};
use serde_json::json;

fn task(agent: &str, args: &[&str]) -> TaskSpec {
    let v = json!({
        "schema_version": 1,
        "id": "t-655",
        "idempotency_key": "issue-655",
        "source": { "repo": "sammasak/nixos-config", "rev": "55b0086" },
        "command": { "agent": agent, "argv": args, "workdir": "." },
        "capabilities": [],
        "resource_class": "small",
        "credential_class": "claude",
        "retry": { "max_attempts": 1 }
    });
    TaskSpec::parse(&v.to_string(), &BTreeSet::new()).unwrap_or_else(|e| unreachable!("{e}"))
}

#[test]
fn claude_runs_print_mode_with_the_prompt_after_the_options() {
    assert_eq!(
        argv(&task("claude", &["-fix the lint"])),
        Ok(vec![
            "claude".into(),
            "-p".into(),
            "--output-format".into(),
            "json".into(),
            "--dangerously-skip-permissions".into(),
            "--".into(),
            "-fix the lint".into(),
        ])
    );
}

#[test]
fn a_named_model_goes_before_the_prompt() {
    let got = argv(&task("claude", &["Read BRIEF.md and do it", "opus"])).unwrap();
    assert_eq!(
        got.get(5..),
        Some(
            &[
                "--model".to_owned(),
                "opus".to_owned(),
                "--".to_owned(),
                "Read BRIEF.md and do it".to_owned()
            ][..]
        )
    );
}

#[test]
fn codex_and_pi_take_the_same_shape() {
    let codex = argv(&task("codex", &["go", "gpt-5"])).unwrap();
    assert_eq!(
        codex.get(..2),
        Some(&["codex".to_owned(), "exec".to_owned()][..])
    );
    assert!(codex.ends_with(&["--model".into(), "gpt-5".into(), "--".into(), "go".into()]));
    assert_eq!(
        argv(&task("pi", &["go"])),
        Ok(vec!["pi".into(), "-p".into(), "--".into(), "go".into()])
    );
}

#[test]
fn a_none_task_runs_its_own_argv() {
    assert_eq!(
        argv(&task("none", &["cargo", "test"])),
        Ok(vec!["cargo".into(), "test".into()])
    );
}

#[test]
fn a_malformed_agent_argv_is_refused() {
    assert_eq!(
        argv(&task("claude", &[""])),
        Err(Error::Argv(Agent::Claude))
    );
    assert_eq!(
        argv(&task("claude", &["a", "b", "c"])),
        Err(Error::Argv(Agent::Claude))
    );
    assert_eq!(
        argv(&task("claude", &["go", "--mcp-config=x"])),
        Err(Error::Model("--mcp-config=x".into()))
    );
    assert_eq!(
        argv(&task("pi", &["go", ""])),
        Err(Error::Model(String::new()))
    );
}

#[test]
fn claude_outcome_follows_its_result_not_its_subtype() {
    let ok = r#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#;
    let err = r#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#;
    assert_eq!(outcome(Agent::Claude, Some(0), ok), Outcome::Succeeded);
    assert_eq!(
        outcome(Agent::Claude, Some(1), &format!("{err}\n\n")),
        Outcome::Failed
    );
}

#[test]
fn an_unknown_result_needs_review() {
    assert_eq!(outcome(Agent::Claude, Some(0), ""), Outcome::NeedsReview);
    assert_eq!(
        outcome(Agent::Claude, Some(1), "panic: oom"),
        Outcome::NeedsReview
    );
    for agent in [Agent::None, Agent::Claude, Agent::Codex, Agent::Pi] {
        assert_eq!(outcome(agent, None, ""), Outcome::NeedsReview);
    }
}

#[test]
fn other_agents_follow_the_exit_code() {
    assert_eq!(outcome(Agent::Codex, Some(0), ""), Outcome::Succeeded);
    assert_eq!(outcome(Agent::Pi, Some(1), ""), Outcome::Failed);
    assert_eq!(outcome(Agent::None, Some(127), ""), Outcome::Failed);
}
