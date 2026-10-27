# Coordinator agent

> **Optional hardened mode, currently disabled on every host.** The coordinator
> and quality roles are delivered as ordinary subagents from the `skills` repo:
> `~/.claude/agents/coordinator.md` and `quality.md` are linked like every other
> agent and run their devenv task DAGs from a writable skills checkout
> (`$SKILLS_CHECKOUT`, default `~/claude-code-skills`). Everything below
> describes the stricter launcher mode (`sam.profile.coordinator`) that pins a
> materialised checkout and a dedicated worker key; enable it only if that
> isolation is wanted.

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
sam.coordinator.identityFile = "/home/lukas/.ssh/id_coordinator";   # dedicated key, never the interactive one
sam.coordinator.fleet = {
  hosts = [ { name = "lenovo"; } { name = "acer-swift"; ssh = "lukas@acer-swift"; } ];
  repos = [ { name = "skills"; gh = "sammasak/skills"; checkout = "/home/lukas/skills"; } ];
};
```

Needs `devTools = true` (Claude Code and Herdr). The skills input must be at a
revision that carries `agents/coordinator.md`, `hooks/role-guard-dispatch.sh` and `task-modules/guard.nix`
(`just bump skills` after the epic PRs merge).

## What gets installed

| Path | Purpose |
|---|---|
| `~/.local/share/coordinator/skills-<rev>` (+ `current` link) | writable copy of the pinned skills input with a project-scoped `.claude/agents/coordinator.md` and `.claude/skills/*` (the launcher loads no user-scope settings) and an `.integrity` manifest the guard checks on every call (its hash is pinned in `~/.config/coordinator/skills-<rev>.integrity.sha256`, guarded files are read-only); devenv runs here |
| `~/.config/coordinator/fleet.json` | hosts and repos from `sam.coordinator.fleet` |
| `coordinator` | launcher: `claude --agent coordinator --permission-mode default --setting-sources project --settings <rendered settings>` from the checkout; user-scope and local settings are not loaded (the checkout carries an empty, read-only, manifest-listed `.claude/settings.json`); the rendered file carries the role's rules plus the host's telemetry env and Herdr hook |

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

## Role adapters are not user-scope agents

`skills.nix` links `agents/*.md` into `~/.claude/agents` on every devTools host
but skips role adapters (an `.md` with a sibling `agents/<name>/` contract):
the launcher project-scopes its adapter inside the pinned checkout, and a
user-scope copy would only attract delegation that the guard refuses outside
the launcher (or that fails closed where the guard is absent).
The quality role has no launcher yet; its adapter is reachable only through
`agents/quality/tests/two-harness.sh`.

## Rollback

The module touches only the paths above. `nixos-rebuild switch --rollback`
(or booting the previous generation) removes the launcher, the hook and
fleet.json when rolling back past the enabling generation; rolling back across
a skills bump re-points `current` at the retained older copy. The activation
keeps the active copy plus the two newest others and prunes the rest; what is
left under `~/.local/share/coordinator` and `~/.local/state/coordinator` can be
deleted by hand. No service units, no secrets, no firewall changes.

Roll back by generation, not by reverting the skills pin alone: with
`sam.profile.coordinator` still enabled, an older skills input has no
`agents/coordinator.md` and evaluation fails (checked on lenovo with the pin
moved back to the pre-epic revision). Disable the profile in the same commit
if the pin must go back.

## Least-privilege SSH to workers

The coordinator reaches a worker only through `ssh <host> …` with the
coordinator user's key. On each worker, list that key under
`sam.coordinator.acceptKeys` and the base role installs it with a forced
command (`herdr-shim`) under `restrict` (no pty, no forwarding, no user rc):

```nix
# hosts/<worker>/configuration.nix
sam.coordinator.acceptKeys = [ "ssh-ed25519 AAAA… coordinator@lenovo" ];
```

The shim accepts only the tasks' transport (`bash -c '<runner>' _ <base64 of
NUL-separated argv>`), decodes the argv itself (no shell re-parse, no `eval`)
and execs it only when it is `herdr agent list|get|read|wait|prompt …` or one
of the two exact session-read one-liners `harness:session-summary` ships,
confined to the user's `~/.claude/projects` and `~/.pi/agent/sessions` stores;
everything else exits 2 with the refused command in the message. Known limits:
`herdr agent prompt` can type into any *detected agent* pane on the worker
(not plain shells), and the `read`/`wait`/`prompt` flags pass through as herdr
defines them (`--lines/--source/--format`, `--until/--timeout`, `--wait`);
none of them writes files. The key must be a dedicated one: the module refuses
a key that is also in the owner's `sshKeys`, because sshd would honour
whichever `authorized_keys` line comes first.

## Boundaries

The guard is registered twice on purpose: in the rendered settings file (the
one Claude honours for `allow` decisions when the agent is the main session,
verified live) and in the agent frontmatter (a backstop for an adapter loaded
outside the launcher's settings, e.g. `--agent coordinator` by hand from a
skills checkout; it fails closed without the host guard). `herdr:message` prompts every time (permission `ask`); the guard refuses any
Bash call that is not `devenv tasks run <allowed task> [--input-json '<object>']
[--show-output]` from the checkout. Read is allowed inside the checkout and the
state directory and denied for key, token and secret paths; the coordinator
reads untrusted pane and session text from other agents, so keep that list
honest. OS-level: on each worker the coordinator's dedicated key is bound to
`herdr-shim` as described above, and the coordinator host sets
`sam.coordinator.identityFile`. The launcher exports it as
`COORDINATOR_SSH_IDENTITY` and the tasks run every fleet ssh as
`ssh -F none -i <key> -o IdentitiesOnly=yes`: no `ssh_config` is read at all,
so no `Host *` `IdentityFile` from `~/.ssh/config` can be appended as a
fallback and no agent key is offered; if a worker rejects the dedicated key the
call fails instead of falling through to an owner key. Fleet targets must
therefore resolve without any ssh_config (DNS or MagicDNS names, `user@` when
the remote user differs); a `Host` alias, `User` or `ProxyJump` defined only in
`~/.ssh/config` is not honoured and shows up as unreachable. The system-wide
`ssh_config` blocks only make a manual `ssh <fleet host>` prefer the same key.
The read-only file modes on the copy are a convenience; the manifest check is
the control (tamper-evident, not tamper-proof: directories stay writable). The
activation runs the guard's own predicate (the skills `guard:integrity` task in the
copy) and rebuilds a copy it would refuse.
