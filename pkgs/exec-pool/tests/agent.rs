use std::collections::BTreeSet;

use exec_pool::agent::{
    AGENT_SOCKET, Error, PREFIX, SESSION_WAIT, Turn, argv, branch, outcome, session_argv,
    transcript_probe, turn_input,
};
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

/// The prompt an agent gets for task `t-655`'s `prompt`.
fn told(prompt: &str) -> String {
    format!("{}{prompt}", PREFIX.replace("{branch}", "pool/t-655"))
}

#[test]
fn every_agent_is_told_to_push_its_own_branch_alone() {
    let t = task("claude", &["go"]);
    assert_eq!(branch(&t).unwrap(), "pool/t-655");
    let prompt = argv(&t).unwrap().pop().unwrap();
    assert!(prompt.ends_with("The task:\n\ngo"), "{prompt}");
    for rule in [
        "on branch pool/t-655",
        "`Why:` line",
        "Elsewhere, `git push origin pool/t-655`",
        "commit and push only through its shell",
        "devenv shell -- git commit",
        "devenv shell -- git push origin pool/t-655",
        "Never push main",
        "never force-push",
        "no --no-verify",
    ] {
        assert!(prompt.contains(rule), "{rule}: {prompt}");
    }
    assert!(!prompt.contains("{branch}"));
    // a plain push is no alternative where a devenv.nix exists: it runs no hook in a fresh clone
    assert!(!prompt.contains(", or `devenv shell"), "{prompt}");
    let long = "x".repeat(101);
    for id in ["-x", "a/b", "a..b", "a b", "ä", &long] {
        let mut bad = t.clone();
        bad.id = id.to_owned();
        assert_eq!(argv(&bad), Err(Error::Branch(id.to_owned())), "{id}");
        assert_eq!(
            bad.validate(&BTreeSet::new()),
            Err(exec_pool::Error::BranchId(id.to_owned())),
            "refused at submit: {id}"
        );
    }
    assert_eq!(
        argv(&task("none", &["true"])).unwrap(),
        ["true"],
        "a none task gets no prompt"
    );
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
            told("-fix the lint"),
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
                told("Read BRIEF.md and do it")
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
    assert!(codex.ends_with(&["--model".into(), "gpt-5".into(), "--".into(), told("go")]));
    assert_eq!(
        argv(&task("pi", &["go"])),
        Ok(vec!["pi".into(), "-p".into(), "--".into(), told("go")])
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

const UUID: &str = "a3a7c578-9125-8a32-a933-73a095d4a27b";

const TOOLS: (&str, &str) = ("/dtach", "/env");

#[test]
fn a_session_turn_runs_interactive_claude_as_a_named_worker_did_and_resumes_it() {
    let t = task("claude", &["fix the lint", "opus"]);
    let start = session_argv(&t, UUID, Turn::Start, TOOLS).unwrap();
    assert_eq!(
        start,
        [
            "/dtach",
            "-N",
            AGENT_SOCKET,
            "/env",
            "TERM=xterm-256color",
            "HERDR_AUTOATTACH_DISABLED=1",
            "fish",
            "-c",
            "claude $argv",
            "--",
            "--dangerously-skip-permissions",
            "--model",
            "opus",
            "--session-id",
            UUID
        ]
    );
    assert!(
        !start.iter().any(|a| a == "-p" || a == "--output-format"),
        "no print mode"
    );
    let resume = session_argv(&t, UUID, Turn::Resume, TOOLS).unwrap();
    assert_eq!(resume[resume.len() - 2..], ["--resume", UUID]);
    let plain = session_argv(&task("claude", &["go"]), UUID, Turn::Start, TOOLS).unwrap();
    assert!(!plain.iter().any(|a| a == "--model"));
}

#[test]
fn an_agent_on_github_is_told_the_rest_calls_for_its_own_pull_request() {
    let mut t = task("claude", &["go"]);
    t.source.repo = "https://github.com/sammasak/nixos-config.git".to_owned();
    let prompt = argv(&t).unwrap().pop().unwrap();
    for call in [
        "gh api repos/sammasak/nixos-config/pulls -f head=pool/t-655 -f base=BASE",
        "gh api repos/sammasak/nixos-config/issues/NUMBER/comments -F body=@FILE",
    ] {
        assert!(prompt.contains(call), "{call}: {prompt}");
    }
    assert!(prompt.ends_with("The task:\n\ngo"), "{prompt}");
    assert!(!prompt.contains("{repo}") && !prompt.contains("{branch}"));
    let session = turn_input(&t, "go", Turn::Start).unwrap();
    assert!(session.contains("repos/sammasak/nixos-config/pulls") && session.contains("pool-wait"));
    assert!(
        !argv(&task("claude", &["go"]))
            .unwrap()
            .concat()
            .contains("gh api"),
        "a repository not on GitHub is told nothing of it"
    );
}

#[test]
fn a_session_turn_is_told_the_prefix_when_it_starts_and_its_input_alone_after() {
    let t = task("claude", &["fix the lint", "opus"]);
    assert_eq!(
        turn_input(&t, "fix the lint", Turn::Start).unwrap(),
        format!(
            "{}fix the lint",
            PREFIX.replace("{branch}", "pool/t-655").replace(
                "The task:",
                &format!("{SESSION_WAIT}{}The task:", exec_pool::agent::SESSION_PARK)
            )
        )
    );
    assert!(
        SESSION_WAIT.contains("pool-wait")
            && SESSION_WAIT.contains("What does not: running processes")
            && SESSION_WAIT.contains("Before you stop or wait, commit and push")
            && SESSION_WAIT.contains("While you wait, send no status messages")
    );
    assert!(
        exec_pool::agent::PULL_REQUEST.contains("not the independent review"),
        "a task that may open a pull request is told to check its own diff first"
    );
    assert!(
        !argv(&t).unwrap().concat().contains("pool-wait"),
        "a one-shot run is not told of pool-wait"
    );
    assert_eq!(
        turn_input(&t, "and the test", Turn::Resume).unwrap(),
        "and the test"
    );
}

#[test]
fn a_session_is_claude_only_with_a_uuid_and_some_input() {
    let t = task("claude", &["go"]);
    for agent in ["codex", "pi", "none"] {
        let other = task(agent, if agent == "none" { &["true"] } else { &["go"] });
        assert!(matches!(
            session_argv(&other, UUID, Turn::Start, TOOLS),
            Err(Error::NoSession(_))
        ));
    }
    for bad in [
        "",
        "not-a-uuid",
        "a3a7c578-9125-8a32-a933-73a095d4a27",
        "--resume",
    ] {
        assert_eq!(
            session_argv(&t, bad, Turn::Start, TOOLS),
            Err(Error::SessionId(bad.to_owned()))
        );
    }
    assert_eq!(turn_input(&t, "", Turn::Resume), Err(Error::Input));
}

#[test]
fn the_probe_looks_for_the_transcript_by_the_session_id_only() {
    assert_eq!(
        transcript_probe("/find", "/session/cur/home", UUID),
        [
            "/find",
            "/session/cur/home/.claude/projects",
            "-mindepth",
            "2",
            "-maxdepth",
            "2",
            "-type",
            "f",
            "-name",
            &format!("{UUID}.jsonl"),
            "-print",
            "-quit"
        ]
    );
}
