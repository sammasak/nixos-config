//! A session turn's Herdr pane, apart from the host: what the helper names it, prompts into it and reads back.
//!
//! The helper starts the turn's agent ([`crate::agent::session_argv`]) and opens a workspace in the host user's Herdr
//! whose pane attaches to it, as a named worker's pane did, named by [`agent_name`] and [`label`]. It prompts the
//! turn's input ([`prompt`]), and the agent is idle when Herdr reports it settled after that prompt ([`TurnWatch`]),
//! as the coordinator waited on a named worker. An idle agent is the session's pause: it stays in its pane for a
//! grace in which the owner or a message ([`mail`]) answers it in place, and only then is closed and parked
//! ([`parks`]). The turn's verdict and result text are the agent's
//! last message in its transcript ([`verdict`]).

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::task_result::{SUBAGENT_CALLS_MAX, SubagentCall};
use crate::workspace::{SESSION_HOME, SESSION_WORK};

/// The longest input prompted as it is; a longer one goes to [`INPUT_FILE`]. A paste is cut near 4000 characters.
pub const PROMPT_MAX: usize = 3000;
/// Where a long input is written for the agent to read, in the session's HOME.
pub const INPUT_FILE: &str = "/session/cur/home/.exec-pool-input.md";
/// What Claude draws once it takes input, as the named workers waited for it.
pub const READY_TEXT: &str = "bypass permissions on";
/// How long the agent must stay settled after the prompt before it counts as idle.
pub const SETTLE_MS: u64 = 5000;
/// What each of Claude's Bash tool commands runs under: `bash -c 'source ~/.claude/shell-snapshots/snapshot-…'`.
///
/// The shell lives as long as its command. A background one outlives the agent's turn, which Herdr then shows idle
/// while the agent waits on it.
pub const TOOL_SHELL: &[u8] = b"/.claude/shell-snapshots/snapshot-";

/// The agent's name in Herdr: the task id as Herdr takes a name (`[a-z][a-z0-9_-]{0,31}`), so `agent list` names
/// the session its pane runs.
#[must_use]
pub fn agent_name(task_id: &str) -> String {
    let mut name: String = task_id
        .chars()
        .map(|c| match c.to_ascii_lowercase() {
            c @ ('a'..='z' | '0'..='9' | '_' | '-') => c,
            _ => '-',
        })
        .collect();
    if !name.starts_with(|c: char| c.is_ascii_lowercase()) {
        name.insert_str(0, "s-");
    }
    name.chars().take(32).collect()
}

/// The workspace's label: the slot, then the task's idempotency key (`coord:OWNER/REPO#N` for the coordinator's).
#[must_use]
pub fn label(slot: &str, key: &str) -> String {
    format!("{slot} {key}")
}

/// Whether a workspace `label` is one of `slot`'s, which the helper closes before and after a turn.
///
/// The bare slot is the standing workspace a slot's session surface held, left behind where that unit was not running to close it.
#[must_use]
pub fn is_slots(label: &str, slot: &str) -> bool {
    label
        .strip_prefix(slot)
        .is_some_and(|r| r.is_empty() || r.starts_with(' '))
}

/// What is prompted for `input`, and what to write to [`INPUT_FILE`] first when it is too long to paste.
#[must_use]
pub fn prompt(input: &str) -> (Option<&str>, String) {
    if input.len() <= PROMPT_MAX {
        (None, input.to_owned())
    } else {
        (
            Some(input),
            format!("Read {INPUT_FILE} and do what it says: it is this turn's input."),
        )
    }
}

/// What Herdr reports of the agent in a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Seen {
    /// `idle` or `done`: waiting for input.
    pub settled: bool,
    /// Herdr's `state_change_seq`, which moves on every change of the agent's state.
    pub seq: u64,
}

/// The agent in `pane` in `herdr agent list`'s output, `None` when Herdr sees none there.
#[must_use]
pub fn seen(list: &Value, pane: &str) -> Option<Seen> {
    let agent = list
        .pointer("/result/agents")?
        .as_array()?
        .iter()
        .find(|a| a.get("pane_id").and_then(Value::as_str) == Some(pane))?;
    Some(Seen {
        settled: matches!(
            agent.get("agent_status").and_then(Value::as_str),
            Some("idle" | "done")
        ),
        seq: agent
            .get("state_change_seq")
            .and_then(Value::as_u64)
            .unwrap_or(0),
    })
}

/// Whether a process the host sees runs in `slot`'s step `unit`, by its `/proc/PID/cgroup`: that unit's cgroup inside
/// the slot's container.
#[must_use]
pub fn in_unit(cgroup: &str, (slot, unit): (&str, &str)) -> bool {
    let container = format!("/container@{slot}.service/");
    let unit = format!("{unit}.service");
    cgroup.lines().any(|l| {
        l.strip_prefix("0::")
            .and_then(|p| p.split_once(&container))
            .is_some_and(|(_, rest)| rest.split('/').any(|c| c == unit))
    })
}

/// Whether a process the host sees is a Bash tool command ([`TOOL_SHELL`]) of the agent in `slot`'s step `unit`:
/// [`in_unit`], and by its `/proc/PID/cmdline`.
#[must_use]
pub fn tool_shell(cgroup: &str, cmdline: &[u8], at: (&str, &str)) -> bool {
    in_unit(cgroup, at) && cmdline.windows(TOOL_SHELL.len()).any(|w| w == TOOL_SHELL)
}

/// A process the host sees, from its `/proc/PID/stat`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub parent: u32,
    pub session: u32,
    /// Clock ticks after boot.
    pub start: u64,
}

impl Proc {
    /// The process `pid`'s `/proc/PID/stat` line describes: after the command's last `)` come its state, parent,
    /// process group and session, and its start time 20th.
    #[must_use]
    pub fn of_stat(pid: u32, stat: &str) -> Option<Self> {
        let f: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
        Some(Self {
            pid,
            parent: f.get(1)?.parse().ok()?,
            session: f.get(3)?.parse().ok()?,
            start: f.get(19)?.parse().ok()?,
        })
    }
}

/// Whether a step unit's processes hold a detached job.
///
/// The unit's main process (`dtach`), its oldest one, has the container's init for its parent. A `nohup` or `setsid`
/// job whose command returned is adopted by that init and stays in the unit's cgroup; it counts only in a session
/// of its own (a tool shell's, or one `setsid` made), so a helper the agent's processes double-fork (Chromium's
/// crashpad under the browser MCP) stays in the agent's session and is passed over. A process whose parent exited
/// mid-read, its adoption not yet seen, is not one.
#[must_use]
pub fn detached(procs: &[Proc]) -> bool {
    let Some(main) = procs
        .iter()
        .filter(|p| !procs.iter().any(|q| q.pid == p.parent))
        .min_by_key(|p| (p.start, p.pid))
    else {
        return false;
    };
    let agent: Vec<u32> = procs
        .iter()
        .filter(|p| [p.pid, p.parent].contains(&main.pid))
        .map(|p| p.session)
        .collect();
    procs
        .iter()
        .any(|p| p.pid != main.pid && p.parent == main.parent && !agent.contains(&p.session))
}

/// Whether a Claude subagent's `meta.json` is one still running.
///
/// Claude writes `~/.claude/projects/<project>/<session>/subagents/agent-<id>.meta.json` at the spawn and again with
/// `"finished": true` once the subagent ends. A background subagent has no process of its own, so Herdr shows its
/// agent idle while it works.
#[must_use]
pub fn subagent_running(meta: &str) -> bool {
    serde_json::from_str::<Value>(meta)
        .is_ok_and(|v| v.is_object() && v.get("finished") != Some(&Value::Bool(true)))
}

/// When the agent is idle: settled after the prompt, waiting for input, with no Bash tool command or subagent of its
/// running.
///
/// That is a state Herdr reached after the prompt, held for [`SETTLE_MS`]. A blocked or working agent, one Herdr does
/// not see, one waiting on its own background command ([`tool_shell`]), detached job ([`detached`]) or subagent ([`subagent_running`]), or a message the owner types in the pane makes
/// it busy again; only the time limit ends a turn that never settles.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnWatch {
    /// The agent's `state_change_seq` just before the prompt.
    before: u64,
    /// The settled state seen, and since when (ms).
    settled: Option<(u64, u64)>,
}

impl TurnWatch {
    #[must_use]
    pub const fn new(before: u64) -> Self {
        Self {
            before,
            settled: None,
        }
    }

    /// How long the agent has been idle once Herdr shows `seen` at `now_ms`, counted from when it settled.
    ///
    /// `None` while it is not, and while `jobs`: a Bash tool command or a subagent of its runs.
    pub const fn idle_ms(&mut self, seen: Option<Seen>, jobs: bool, now_ms: u64) -> Option<u64> {
        match seen {
            Some(s) if s.settled && !jobs && s.seq > self.before => {
                let since = match self.settled {
                    Some((seq, since)) if seq == s.seq => since,
                    _ => now_ms,
                };
                self.settled = Some((s.seq, since));
                let idle = now_ms.saturating_sub(since);
                if idle >= SETTLE_MS { Some(idle) } else { None }
            }
            _ => {
                self.settled = None;
                None
            }
        }
    }
}

/// Whether an agent idle for `idle_ms` is closed and its session parked.
///
/// That is once idle for the pause's grace `grace_secs`, in which the owner or a message may still answer it in place, or at once when it asked for a timer
/// (`waiting`, its `pool-wait`).
#[must_use]
pub const fn parks(idle_ms: Option<u64>, grace_secs: u64, waiting: bool) -> bool {
    match idle_ms {
        Some(ms) => waiting || ms >= grace_secs.saturating_mul(1000),
        None => false,
    }
}

/// The messages sent to the session during its turn that the agent was not given yet (`delivered` the last one
/// given), as one input and the highest id; `None` if none.
#[must_use]
pub fn mail(messages: &[(i64, String)], delivered: i64) -> Option<(String, i64)> {
    let new: Vec<&(i64, String)> = messages.iter().filter(|(id, _)| *id > delivered).collect();
    let upto = new.iter().map(|(id, _)| *id).max()?;
    let text = new
        .iter()
        .map(|(_, b)| b.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    Some((text, upto))
}

/// How many lines of `transcript` [`verdict`] counts: those that are JSON.
#[must_use]
pub fn count(transcript: &str) -> usize {
    transcript
        .lines()
        .filter(|l| serde_json::from_str::<Value>(l).is_ok())
        .count()
}

/// The turn's verdict as a Claude result line, and whether the agent got the prompt at all.
///
/// It reads the transcript's JSON lines after the first `from` ([`count`] before the prompt), as the result line [`crate::task_result::TaskResult::of`] and [`crate::agent::outcome`] read; the agent got the
/// prompt when a user or assistant line follows.
///
/// The result is the last assistant message's text; it is an error unless the turn `ended` settled with one. Tokens
/// are the assistant messages' usage, each message once; the cost is what Claude's `cost-state` grew by, when one
/// was written. `None`: the runner read no transcript, so its subagent calls are unknown (null), not none.
#[must_use]
pub fn verdict(transcript: Option<&str>, from: usize, ended: bool) -> (String, bool) {
    let lines: Vec<Value> = transcript
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let kind = |v: &Value| v.get("type").and_then(Value::as_str).map(str::to_owned);
    let (before, after) = lines.split_at(from.min(lines.len()));
    let ran = after
        .iter()
        .any(|v| matches!(kind(v).as_deref(), Some("user" | "assistant")));
    let assistant: Vec<&Value> = after
        .iter()
        .filter(|v| kind(v).as_deref() == Some("assistant"))
        .collect();
    let text = assistant.iter().rev().find_map(|v| {
        let parts: Vec<&str> = v
            .pointer("/message/content")?
            .as_array()?
            .iter()
            .filter(|c| c.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|c| c.get("text").and_then(Value::as_str))
            .collect();
        (!parts.is_empty()).then(|| parts.join("\n"))
    });
    let mut usage: BTreeMap<String, &Value> = BTreeMap::new();
    for (i, v) in assistant.iter().enumerate() {
        if let Some(u) = v.pointer("/message/usage") {
            let id = v
                .pointer("/message/id")
                .and_then(Value::as_str)
                .map_or_else(|| i.to_string(), str::to_owned);
            usage.insert(id, u);
        }
    }
    let (calls, count) = transcript.map(|_| subagent_calls(&assistant)).unzip();
    let sum = |k: &str| {
        usage
            .values()
            .filter_map(|u| u.get(k).and_then(Value::as_u64))
            .fold(0_u64, u64::saturating_add)
    };
    let cost_state = |vs: &[Value]| {
        vs.iter()
            .rev()
            .find(|v| kind(v).as_deref() == Some("cost-state"))
            .cloned()
    };
    let cost = cost_state(after).and_then(|now| {
        let total = now.get("totalCostUSD")?.as_f64()?;
        // a resumed process that carries on its predecessor's state starts from it
        let carried = cost_state(before)
            .filter(|b| b.get("startTime").is_some() && b.get("startTime") == now.get("startTime"))
            .and_then(|b| b.get("totalCostUSD")?.as_f64())
            .unwrap_or(0.0);
        Some((total - carried).max(0.0))
    });
    let is_error = !(ended && text.is_some());
    let result = text.unwrap_or_else(|| {
        if ended {
            "the turn ended with no message from the agent".to_owned()
        } else {
            "the agent left before its turn ended".to_owned()
        }
    });
    let line = json!({
        "is_error": is_error,
        "result": result,
        "usage": {
            "input_tokens": sum("input_tokens"),
            "output_tokens": sum("output_tokens"),
            "cache_read_input_tokens": sum("cache_read_input_tokens"),
            "cache_creation_input_tokens": sum("cache_creation_input_tokens"),
        },
        "total_cost_usd": cost,
        "subagent_calls": calls,
        "subagent_call_count": count,
    });
    (line.to_string(), ran)
}

/// The Agent (formerly Task) tool calls in `assistant`, the session's own (no subagent's sidechain), each tool use
/// once: the first [`SUBAGENT_CALLS_MAX`] as their short description and subagent type, never their prompt, and how many
/// there were.
fn subagent_calls(assistant: &[&Value]) -> (Vec<SubagentCall>, usize) {
    let mut seen = std::collections::BTreeSet::new();
    let mut calls = Vec::new();
    for (i, v) in assistant.iter().enumerate() {
        if v.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(parts) = v.pointer("/message/content").and_then(Value::as_array) else {
            continue;
        };
        for (j, c) in parts.iter().enumerate() {
            let tool = c.get("name").and_then(Value::as_str);
            if c.get("type").and_then(Value::as_str) != Some("tool_use")
                || !matches!(tool, Some("Agent" | "Task"))
            {
                continue;
            }
            let id = c
                .get("id")
                .and_then(Value::as_str)
                .map_or_else(|| format!("{i}.{j}"), str::to_owned);
            if seen.insert(id) {
                let field = |k: &str| c.pointer(&format!("/input/{k}")).and_then(Value::as_str);
                calls.push(SubagentCall::new(
                    field("description"),
                    field("subagent_type"),
                ));
            }
        }
    }
    let count = calls.len();
    calls.truncate(SUBAGENT_CALLS_MAX);
    (calls, count)
}

/// The session HOME's `~/.claude.json` with the startup dialogs a named worker's home has accepted.
///
/// As Home Manager's `acceptClaudeStartupDialogs` does: onboarding, bypass mode and the trust of the session's HOME and checkout, so
/// interactive Claude starts at its prompt. `None` keeps a file that is not one JSON object as it is.
#[must_use]
pub fn accept_dialogs(current: Option<&str>) -> Option<String> {
    let mut o: Map<String, Value> = match current {
        None => Map::new(),
        Some(s) => match serde_json::from_str(s) {
            Ok(Value::Object(o)) => o,
            _ => return None,
        },
    };
    for k in [
        "bypassPermissionsModeAccepted",
        "hasSeenAutoDefaultNudge",
        "hasCompletedOnboarding",
        "hasSeenAutoModeEntryWarning",
    ] {
        o.insert(k.to_owned(), Value::Bool(true));
    }
    o.entry("lastOnboardingVersion")
        .or_insert_with(|| json!("2.1.300"));
    o.entry("theme").or_insert_with(|| json!("dark"));
    let projects = o.entry("projects").or_insert_with(|| json!({}));
    if !projects.is_object() {
        *projects = json!({});
    }
    if let Value::Object(p) = projects {
        for d in [SESSION_HOME, SESSION_WORK] {
            let e = p.entry(d).or_insert_with(|| json!({}));
            if !e.is_object() {
                *e = json!({});
            }
            if let Value::Object(e) = e {
                e.insert("hasTrustDialogAccepted".to_owned(), Value::Bool(true));
            }
        }
    }
    Some(Value::Object(o).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_agent_is_named_by_its_task_and_its_workspace_by_slot_and_key() {
        assert_eq!(agent_name("cli-73d5095ae21b38b7"), "cli-73d5095ae21b38b7");
        assert_eq!(agent_name("Coord_7.X"), "coord_7-x");
        assert_eq!(agent_name("7up"), "s-7up");
        assert_eq!(agent_name(&"a".repeat(40)).len(), 32);
        let l = label("pool1", "coord:sammasak/nixos-config#7");
        assert_eq!(l, "pool1 coord:sammasak/nixos-config#7");
        assert!(is_slots(&l, "pool1"));
        assert!(!is_slots(&l, "pool"));
        assert!(!is_slots("pool10 x", "pool1"));
        assert!(is_slots("pool1", "pool1") && !is_slots("pool10", "pool1"));
    }

    #[test]
    fn a_long_input_is_written_to_a_file_and_the_prompt_names_it() {
        assert_eq!(prompt("fix it"), (None, "fix it".to_owned()));
        let long = "x".repeat(PROMPT_MAX + 1);
        let (file, p) = prompt(&long);
        assert_eq!(file, Some(long.as_str()));
        assert!(p.contains(INPUT_FILE) && p.len() < PROMPT_MAX);
    }

    fn list(status: &str, seq: u64) -> Value {
        json!({ "result": { "agents": [
            { "pane_id": "w2:p1", "agent_status": "working", "state_change_seq": 99 },
            { "pane_id": "w1:p1", "agent_status": status, "state_change_seq": seq }
        ] } })
    }

    #[test]
    fn herdr_s_list_is_read_for_the_turn_s_pane_alone() {
        assert_eq!(
            seen(&list("idle", 3), "w1:p1"),
            Some(Seen {
                settled: true,
                seq: 3
            })
        );
        assert_eq!(
            seen(&list("done", 4), "w1:p1").map(|s| s.settled),
            Some(true)
        );
        for busy in ["working", "blocked", "unknown"] {
            assert_eq!(
                seen(&list(busy, 4), "w1:p1").map(|s| s.settled),
                Some(false)
            );
        }
        assert_eq!(seen(&list("idle", 3), "w3:p1"), None);
        assert_eq!(seen(&json!({ "result": {} }), "w1:p1"), None);
    }

    #[test]
    fn the_agent_is_idle_once_it_stays_settled_at_a_state_after_the_prompt() {
        let s = |settled, seq| Some(Seen { settled, seq });
        let mut w = TurnWatch::new(1);
        // idle before the prompt took: the state it was prompted in
        assert_eq!(w.idle_ms(s(true, 1), false, 0), None);
        assert_eq!(w.idle_ms(s(true, 1), false, 60_000), None);
        assert_eq!(w.idle_ms(s(false, 2), false, 61_000), None);
        assert_eq!(w.idle_ms(s(true, 3), false, 62_000), None);
        assert_eq!(w.idle_ms(s(true, 3), false, 62_000 + SETTLE_MS - 1), None);
        assert_eq!(
            w.idle_ms(s(true, 3), false, 62_000 + SETTLE_MS),
            Some(SETTLE_MS)
        );
        assert_eq!(w.idle_ms(s(true, 3), false, 662_000), Some(600_000));

        // working again (a tool's gap, the owner typed into the pane, a message was prompted): it starts over
        let mut w = TurnWatch::new(1);
        assert_eq!(w.idle_ms(s(true, 3), false, 0), None);
        assert_eq!(w.idle_ms(s(true, 3), false, 100_000), Some(100_000));
        assert_eq!(w.idle_ms(s(false, 4), false, 101_000), None);
        assert_eq!(w.idle_ms(s(true, 5), false, 102_000), None);
        assert_eq!(
            w.idle_ms(s(true, 5), false, 102_000 + SETTLE_MS),
            Some(SETTLE_MS)
        );

        // a turn quicker than a poll: settled at a later state, never seen working
        let mut w = TurnWatch::new(1);
        assert_eq!(w.idle_ms(s(true, 3), false, 0), None);
        assert_eq!(w.idle_ms(s(true, 3), false, SETTLE_MS), Some(SETTLE_MS));

        // no agent in the pane, or one at a dialog, is not idle
        let mut w = TurnWatch::new(1);
        assert_eq!(w.idle_ms(s(true, 3), false, 0), None);
        assert_eq!(w.idle_ms(None, false, 1000), None);
        assert_eq!(w.idle_ms(s(true, 3), false, 2000), None);
        assert_eq!(w.idle_ms(s(false, 9), false, 100_000), None);
    }

    #[test]
    fn a_bash_tool_command_is_told_by_its_shell_and_its_slot_s_unit() {
        let cg = "0::/system.slice/container@pool3.service/payload/system.slice/exec-pool-task.service\n";
        let tool = b"/run/current-system/sw/bin/bash\0-c\0source /session/cur/home/.claude/shell-snapshots/snapshot-bash-1-x.sh 2>/dev/null && eval 'nix build' \0";
        let at = ("pool3", "exec-pool-task");
        assert!(tool_shell(cg, tool, at));
        // the agent itself, its MCP servers, another slot's or another step's shell are not
        assert!(!tool_shell(cg, b"claude\0--session-id\0x\0", at));
        assert!(!tool_shell(
            cg,
            b"node\0/nix/store/x-playwright-mcp/cli.js\0",
            at
        ));
        assert!(!tool_shell(cg, tool, ("pool1", "exec-pool-task")));
        assert!(!tool_shell(cg, tool, ("pool3", "exec-pool-probe")));
        assert!(!tool_shell(&cg.replace("pool3", "pool30"), tool, at));
        assert!(!tool_shell("", tool, at));
    }

    #[test]
    fn a_detached_job_is_one_init_adopted_outside_the_agent_s_sessions() {
        let stat = "24134 (a) b) S 1 24134 24134 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 9876 2 3";
        assert_eq!(
            Proc::of_stat(24134, stat),
            Some(Proc {
                pid: 24134,
                parent: 1,
                session: 24134,
                start: 9876
            }),
            "a command name holding a parenthesis"
        );
        assert_eq!(Proc::of_stat(1, ""), None);
        let p = |pid, parent, session, start| Proc {
            pid,
            parent,
            session,
            start,
        };
        // as a slot showed it: dtach (its own session), fish and claude in the pty's, an MCP server, a tool shell
        let tree = [
            p(10, 1, 10, 100),
            p(11, 10, 11, 101),
            p(12, 11, 11, 102),
            p(13, 12, 11, 103),
            p(14, 12, 14, 500),
        ];
        assert!(!detached(&tree));
        assert!(!detached(&[]));
        let with = |more: Proc| [tree.as_slice(), &[more]].concat();
        assert!(detached(&with(p(20, 1, 20, 600))), "a setsid job");
        assert!(
            detached(&with(p(21, 1, 14, 600))),
            "a nohup job whose shell exited"
        );
        assert!(
            !detached(&with(p(22, 14, 14, 600))),
            "a job its shell still waits on is the shell's"
        );
        assert!(
            !detached(&with(p(23, 1, 11, 600))),
            "a helper the agent double-forked, crashpad"
        );
        assert!(
            !detached(&with(p(24, 99, 24, 600))),
            "its parent exited mid-read, its adoption not yet seen"
        );
    }

    #[test]
    fn a_subagent_runs_until_its_meta_says_finished() {
        // as Claude Code 2.1 writes them: at the spawn, and once the subagent ended
        let spawned = r#"{"agentType":"general-purpose","isBuiltIn":true,"description":"x","toolUseId":"toolu_1","spawnDepth":1,"requestShape":"background","requestNonInteractive":true,"model":"haiku"}"#;
        assert!(subagent_running(spawned));
        assert!(!subagent_running(&spawned.replace(
            r#""model":"haiku"}"#,
            r#""model":"haiku","finished":true}"#
        )));
        // half written, or not a meta at all: not a running subagent
        assert!(!subagent_running(r#"{"agentType":"#));
        assert!(!subagent_running("[]"));
        assert!(!subagent_running(""));
    }

    #[test]
    fn an_agent_waiting_on_its_own_background_command_is_not_idle() {
        let s = Some(Seen {
            settled: true,
            seq: 3,
        });
        let mut w = TurnWatch::new(1);
        assert_eq!(w.idle_ms(s, true, 0), None);
        assert_eq!(w.idle_ms(s, true, 3_600_000), None);
        assert!(!parks(w.idle_ms(s, true, 3_600_000), 0, true));
        // the command ended: settled from then on, a fresh settle
        assert_eq!(w.idle_ms(s, false, 3_600_000), None);
        assert_eq!(w.idle_ms(s, false, 3_600_000 + SETTLE_MS), Some(SETTLE_MS));
    }

    #[test]
    fn an_idle_agent_parks_after_its_grace_or_at_once_for_a_timer() {
        assert!(!parks(None, 600, false));
        assert!(!parks(None, 0, true));
        assert!(!parks(Some(SETTLE_MS), 600, false));
        assert!(!parks(Some(599_999), 600, false));
        assert!(parks(Some(600_000), 600, false));
        assert!(parks(Some(60_000), 60, false));
        assert!(parks(Some(SETTLE_MS), 600, true));
    }

    #[test]
    fn mail_during_the_turn_is_handed_over_once() {
        let m = [
            (4, "review: fix the test".to_owned()),
            (6, "and rebase".to_owned()),
        ];
        assert_eq!(
            mail(&m, 3),
            Some(("review: fix the test\n\nand rebase".to_owned(), 6))
        );
        assert_eq!(mail(&m, 4), Some(("and rebase".to_owned(), 6)));
        assert_eq!(mail(&m, 6), None);
        assert_eq!(mail(&[], 0), None);
    }

    const OLD: &str = r#"{"type":"user","message":{"role":"user","content":"first"}}
{"type":"assistant","message":{"id":"m0","content":[{"type":"text","text":"old answer"}],"usage":{"input_tokens":50}}}
{"type":"cost-state","totalCostUSD":0.5,"startTime":1}"#;

    fn transcript(new: &str) -> String {
        format!("{OLD}\n{new}")
    }

    fn line(v: &str) -> Value {
        serde_json::from_str(v).unwrap()
    }

    #[test]
    fn the_verdict_is_the_last_assistant_text_after_the_prompt() {
        let t = transcript(
            r#"{"type":"user","message":{"role":"user","content":"now"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"working on it"},{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":3,"output_tokens":5}}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"thinking","thinking":"hm"}],"usage":{"input_tokens":4,"output_tokens":1,"cache_read_input_tokens":100}}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"opened PR #9"}],"usage":{"input_tokens":4,"output_tokens":7,"cache_read_input_tokens":100}}}
not json
{"type":"cost-state","totalCostUSD":0.75,"startTime":2}"#,
        );
        let (v, ran) = verdict(Some(&t), 3, true);
        let v = line(&v);
        assert!(ran);
        assert_eq!(v["is_error"], false);
        assert_eq!(v["result"], "opened PR #9");
        // each message once, the old turn's not at all
        assert_eq!(v["usage"]["input_tokens"], 7);
        assert_eq!(v["usage"]["output_tokens"], 12);
        assert_eq!(v["usage"]["cache_read_input_tokens"], 100);
        assert_eq!(v["total_cost_usd"], 0.75);
        // the same through what the runner reads
        let r = crate::task_result::TaskResult::of(crate::Agent::Claude, None, &format!("{v}\n"));
        assert_eq!(r.output(), "opened PR #9");
        assert_eq!(r.usage.unwrap().output_tokens, 12);
    }

    #[test]
    fn the_turn_s_subagent_calls_are_named_without_their_prompts() {
        let t = transcript(
            r#"{"type":"user","message":{"role":"user","content":"now"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Review PR 9","subagent_type":"code-reviewer","prompt":"SECRET-PROMPT-1"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"SECRET-OUTPUT"}]}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"description":"Review PR 9","subagent_type":"code-reviewer","prompt":"SECRET-PROMPT-1"}}]}}
{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls","description":"List files"}}]}}
{"type":"assistant","isSidechain":true,"message":{"id":"s1","content":[{"type":"tool_use","id":"s9","name":"Agent","input":{"description":"nested","prompt":"x"}}]}}
{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"Task","input":{"description":"Find callers","prompt":"SECRET-PROMPT-2"}},{"type":"text","text":"done"}]}}"#,
        );
        let (v, _) = verdict(Some(&t), 3, true);
        assert!(!v.contains("SECRET"), "{v}");
        let r = crate::task_result::TaskResult::of(crate::Agent::Claude, None, &format!("{v}\n"));
        assert_eq!(r.subagent_call_count, Some(2), "{v}");
        assert_eq!(
            r.subagent_calls.unwrap(),
            [
                SubagentCall::new(Some("Review PR 9"), Some("code-reviewer")),
                SubagentCall::new(Some("Find callers"), None),
            ]
        );
        let none = line(
            &verdict(
                Some(&transcript(r#"{"type":"user","message":{}}"#)),
                3,
                true,
            )
            .0,
        );
        assert_eq!(
            (
                none["subagent_calls"].clone(),
                none["subagent_call_count"].clone()
            ),
            (json!([]), json!(0))
        );
        // a transcript the runner could not read tells nothing, not that no subagent was called
        let unread = line(&verdict(None, 0, false).0);
        assert!(unread["subagent_calls"].is_null() && unread["subagent_call_count"].is_null());
        let many = (0..=SUBAGENT_CALLS_MAX)
            .map(|i| format!(r#"{{"type":"assistant","message":{{"id":"m{i}","content":[{{"type":"tool_use","id":"t{i}","name":"Agent","input":{{"description":"d{i}"}}}}]}}}}"#))
            .collect::<Vec<_>>()
            .join("\n");
        let many = line(&verdict(Some(&transcript(&many)), 3, true).0);
        assert_eq!(many["subagent_call_count"], SUBAGENT_CALLS_MAX + 1);
        assert_eq!(
            many["subagent_calls"].as_array().map(Vec::len),
            Some(SUBAGENT_CALLS_MAX)
        );
    }

    #[test]
    fn a_resumed_process_s_carried_cost_is_not_counted_again() {
        let t = transcript(
            r#"{"type":"user","message":{"role":"user","content":"now"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"done"}]}}
{"type":"cost-state","totalCostUSD":0.75,"startTime":1}"#,
        );
        let v = line(&verdict(Some(&t), 3, true).0);
        assert_eq!(v["total_cost_usd"], 0.25);
        let none = line(
            &verdict(
                Some(&transcript(r#"{"type":"user","message":{}}"#)),
                3,
                true,
            )
            .0,
        );
        assert_eq!(none["total_cost_usd"], Value::Null);
    }

    #[test]
    fn a_turn_that_did_not_settle_or_said_nothing_is_an_error() {
        let said = transcript(
            r#"{"type":"user","message":{"role":"user","content":"now"}}
{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"half"}]}}"#,
        );
        let (v, ran) = verdict(Some(&said), 3, false);
        assert!(ran);
        assert_eq!(line(&v)["is_error"], true);
        assert_eq!(line(&v)["result"], "half");
        let silent = transcript(r#"{"type":"user","message":{"role":"user","content":"now"}}"#);
        let v = line(&verdict(Some(&silent), 3, true).0);
        assert_eq!(v["is_error"], true);
        // the old turn's message is not this one's
        assert_ne!(v["result"], "old answer");
    }

    #[test]
    fn a_prompt_that_never_reached_the_agent_is_told_apart() {
        let (_, ran) = verdict(Some(&transcript(r#"{"type":"permission-mode"}"#)), 3, true);
        assert!(!ran);
        let (_, ran) = verdict(None, 0, false);
        assert!(!ran);
    }

    #[test]
    fn the_session_home_accepts_the_startup_dialogs_a_worker_home_does() {
        let fresh = line(&accept_dialogs(None).unwrap());
        assert_eq!(fresh["hasCompletedOnboarding"], true);
        assert_eq!(fresh["bypassPermissionsModeAccepted"], true);
        assert_eq!(fresh["theme"], "dark");
        assert_eq!(
            fresh["projects"][SESSION_WORK]["hasTrustDialogAccepted"],
            true
        );
        assert_eq!(
            fresh["projects"][SESSION_HOME]["hasTrustDialogAccepted"],
            true
        );
        let kept = line(
            &accept_dialogs(Some(
                r#"{"userID":"u","theme":"light","projects":{"/session/cur/work":{"allowedTools":["x"]}}}"#,
            ))
            .unwrap(),
        );
        assert_eq!(kept["userID"], "u");
        assert_eq!(kept["theme"], "light");
        assert_eq!(kept["projects"][SESSION_WORK]["allowedTools"][0], "x");
        assert_eq!(
            kept["projects"][SESSION_WORK]["hasTrustDialogAccepted"],
            true
        );
        assert_eq!(accept_dialogs(Some("")), None);
        assert_eq!(accept_dialogs(Some("[]")), None);
    }
}
