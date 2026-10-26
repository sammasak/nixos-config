# Coordinator agent

The Coordinator (skills epic #16) is the owner's conversational interface to
the fleet's coding agents. It only runs devenv tasks from a pinned skills
checkout: `coord:brief`, `herdr:*`, `harness:*`, `gh:*`, `git:*`, `work:status`.
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
| `~/.local/share/coordinator/skills-<rev>` (+ `current` link) | writable copy of the pinned skills input; devenv runs here |
| `~/.config/coordinator/fleet.json` | hosts and repos from `sam.coordinator.fleet` |
| `~/.claude/hooks/validate-coordinator.sh` | the agent-scoped guard (fails closed when absent) |
| `~/.claude/agents/coordinator.md` | via `skills.nix` (devTools) |
| `coordinator` | launcher: `claude --agent coordinator --permission-mode default --settings <rendered permissions>` from the checkout |

## Run

From a Herdr pane on the host (persistent across SSH disconnects):

```bash
coordinator
```

First start evaluates the devenv graph (tens of seconds, then cached). Ask
"what are my agents doing" or run `devenv tasks run coord:brief --show-output`
in the checkout yourself.

## Verify after activation

```bash
coordinator --print "List my agents and say whether anything needs me."   # expect only coord:brief calls
cd ~/.local/share/coordinator/current && devenv tasks run skills:test        # repo gates
tail -3 ~/.local/state/coordinator/audit.jsonl                               # empty until a message is sent
```

## Rollback

The module touches only the paths above. `nixos-rebuild switch --rollback`
(or booting the previous generation) removes the launcher, the hook and
fleet.json; the materialised checkout copies and `~/.local/state/coordinator`
stay on disk and can be deleted by hand. No service units, no secrets, no
firewall changes.

## Boundaries

`herdr:message` prompts every time (permission `ask`); the guard refuses any
Bash call that is not `devenv tasks run <allowed task> [--input-json '<object>']
[--show-output]` from the checkout. OS-level: the coordinator uses the user's
own SSH identity for `ssh <host> herdr agent …`; a restricted command key per
worker host is tracked in the epic as follow-up.
