# Coordinator agent

The Coordinator (skills epic #16) is the owner's conversational interface to
the fleet's coding agents. It only runs devenv tasks from a pinned skills
checkout: `coord:brief` and `work:status` directly (they fan out over the
`herdr:*`, `harness:*`, `gh:*`, `git:*` tasks), `herdr:inventory`, and the
input-driven reads the guard allows (`herdr:inspect`, `harness:session-summary`,
`coord:handoff`, `herdr:await`); `herdr:message` prompts every time.
It never codes, builds, merges, deploys or approves.

## Enable

```nix
# hosts/<host>/variables.nix
coordinator = true;

# hosts/<host>/configuration.nix
sam.coordinator.fleet = {
  hosts = [ { name = "lenovo"; } { name = "acer-swift"; ssh = "lukas@acer-swift"; } ];
  repos = [ { name = "skills"; gh = "sammasak/skills"; checkout = "/home/lukas/skills"; } ];
};
```

Needs `devTools = true` (Claude Code and Herdr). The skills input must be at a
revision that carries `agents/coordinator.md` and `hooks/validate-coordinator.sh`
(`just bump skills` after the epic PRs merge).

## What gets installed

| Path | Purpose |
|---|---|
| `~/.local/share/coordinator/skills-<rev>` (+ `current` link) | writable copy of the pinned skills input with a project-scoped `.claude/agents/coordinator.md` and `.claude/skills/*` (the launcher loads no user-scope settings) and an `.integrity` manifest the guard checks on every call; devenv runs here |
| `~/.config/coordinator/fleet.json` | hosts and repos from `sam.coordinator.fleet` |
| `~/.claude/hooks/validate-coordinator.sh` | the agent-scoped guard (fails closed when absent) |
| `~/.claude/agents/coordinator.md` | via `skills.nix` on every devTools host; without the guard its hook command refuses every Bash call |
| `coordinator` | launcher: `claude --agent coordinator --permission-mode default --setting-sources project,local --settings <rendered settings>` from the checkout; user-scope settings (which allow bare Read/Bash) are not loaded, the rendered file carries the role's rules plus the host's telemetry env and Herdr hook |

## Run

From a Herdr pane on the host (persistent across SSH disconnects):

```bash
coordinator
```

First start evaluates the devenv graph (tens of seconds, then cached) and, after
each skills bump, shows Claude's trust dialog for the new checkout directory
once. Ask
"what are my agents doing" or run `devenv tasks run coord:brief --show-output`
in the checkout yourself.

## Verify after activation

```bash
coordinator -p "Which agent are you, which skills were preloaded, and what are my agents doing?"
# expect: Coordinator / claude-sonnet-5-5 / herdr-operations + agent-handoff; tool calls are Read inside the checkout plus `devenv tasks run coord:brief|work:status`
cd ~/.local/share/coordinator/current && devenv tasks run skills:test        # repo gates
tail -3 ~/.local/state/coordinator/audit.jsonl                               # written by herdr:message (epic M2); absent until a message is sent
```

## Rollback

The module touches only the paths above. `nixos-rebuild switch --rollback`
(or booting the previous generation) removes the launcher, the hook and
fleet.json when rolling back past the enabling generation; rolling back across
a skills bump re-points `current` at the retained older copy. The activation
keeps the active copy plus the two newest others and prunes the rest; what is
left under `~/.local/share/coordinator` and `~/.local/state/coordinator` can be
deleted by hand. No service units, no secrets, no firewall changes.

## Least-privilege SSH to workers

The coordinator reaches a worker only through `ssh <host> …` with the
coordinator user's key. On each worker, list that key under
`sam.coordinator.acceptKeys` and the base role installs it with a forced
command (`herdr-shim`), `no-pty` and no forwarding:

```nix
# hosts/<worker>/configuration.nix
sam.coordinator.acceptKeys = [ "ssh-ed25519 AAAA… coordinator@lenovo" ];
```

The shim decodes the tasks' `echo <b64> | base64 -d | bash` transport and runs
the inner argv only when it is `herdr agent list|get|read|wait|prompt …` or
the bounded `tail -n N <session file>` one-liner `harness:session-summary`
ships; everything else exits 2 with the refused command in the message. Use a
dedicated key for the coordinator so the owner's own interactive key is not
affected.

## Boundaries

The guard is registered twice on purpose: in the rendered settings file (the
one Claude honours for `allow` decisions when the agent is the main session,
verified live) and in the agent frontmatter (fails closed on hosts without the
launcher). `herdr:message` prompts every time (permission `ask`); the guard refuses any
Bash call that is not `devenv tasks run <allowed task> [--input-json '<object>']
[--show-output]` from the checkout. Read is allowed inside the checkout and the
state directory and denied for key, token and secret paths; the coordinator
reads untrusted pane and session text from other agents, so keep that list
honest. OS-level: the coordinator uses the user's own SSH identity for
`ssh <host> herdr agent …`; a restricted command key per worker host is tracked
in the epic as follow-up.
