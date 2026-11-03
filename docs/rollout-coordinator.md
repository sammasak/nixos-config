# Coordinator rollout: lenovo coordinates, acer executes

**Status: prepared, WAITING FOR OWNER DEPLOY APPROVAL.** Nothing here has been
switched on either host. Tracking: #111, sammasak/skills#28.

## What changes

| Host | Claude Code | Codex |
|---|---|---|
| lenovo (coordinator: declares `sam.herdr.machines`) | `~/.claude/agents/coordinator.md` from the skills input | `[agents.coordinator] config_file` in `~/.codex/config.toml`, pointing at the skills input's `agents/coordinator/codex.toml` as shipped (a regular store file: Codex re-reads it with `O_NOFOLLOW` at spawn, so it is not symlinked into `~/.codex/agents`); its instructions point Codex at `agents/coordinator/ROLE.md`; the role's skills `herdr`, `herdr-operations`, `agent-handoff` added to `~/.agents/skills` and `~/.codex/skills` |
| acer-swift (worker) | every adapter except `coordinator.md`; all shared skills | unchanged (portable skills) |

Both hosts move the skills input to `2704cd0` (skills main after #32, #34 and #33), so every linked skill and
adapter follows it. gh, herdr and devenv are already on both hosts. No package,
service, timer or daemon is added: the system and user unit lists of both
toplevels are identical to main's, and `nix store diff-closures` against main
shows only the skills source and, on lenovo, the coordinator file links.

## Exact revisions (built on acer-swift, 2026-11-03)

| | Value |
|---|---|
| nixos-config base | `120d41fc` (main, after #113) |
| skills input | `2704cd03bdb21be63218bceb1f6508f1ebf95958` (hosts run `08e300a` today), narHash `sha256-omhRah9NneaUqOJLEoGPocQPE1jDzms4I19nl4gyTlc=` |
| lenovo toplevel | `/nix/store/7idvnqw1ydpg0dyxjy2fdgm5qqpp9329-nixos-system-lenovo-21CB001PMX-26.11.20261015.fe13242` (main: `vrpl51lg…`) |
| acer-swift toplevel | `/nix/store/5wbj1b1piwbkirlv4r38yq0mwradw8q4-nixos-system-acer-swift-26.11.20261015.fe13242` (main: `10xvx80a…`) |
| Codex adapter | `/nix/store/9ka734f0dy79z86lwssvagvlrpnff40b-source/agents/coordinator/codex.toml` |

The toplevel hashes hold for the PR head that was built; a later commit on the
branch or a rebase changes them, so rebuild and compare before switching.

## Before switching

- Park agent sessions on the host: a switch breaks the Bash tool of every
  running Claude Code session there (stale shell snapshots).
- On lenovo, make the writable skills checkout match the pin, because the
  coordinator's tasks run from it, not from the store:
  `git -C ~/claude-code-skills fetch && git -C ~/claude-code-skills status -sb`
  then bring `main` to `2704cd0` (or later) without discarding local work.
- `just diff` on each host: expect no bootloader or kernel store-path change.

## Switch (owner)

Lenovo first, then acer. Both commands need a real terminal: `just switch`
runs `sudo nixos-rebuild`, and lukas has no passwordless sudo.

```sh
# on lenovo, in ~/nixos-config at the merged commit
just switch                 # nixos-rebuild switch --install-bootloader for .#lenovo

# then, from lenovo
just deploy-acer            # deploy-rs, magic rollback if acer stops answering
```

## Validate

On lenovo:

```sh
readlink -f ~/.claude/agents/coordinator.md          # .../<skills 2704cd0 source>/agents/coordinator.md
python3 -c 'import os,tomllib; c=tomllib.load(open(os.path.expanduser("~/.codex/config.toml"),"rb")); f=c["agents"]["coordinator"]["config_file"]; os.close(os.open(f, os.O_RDONLY|os.O_NOFOLLOW)); print(f, "model" in c)'   # <store>/agents/coordinator/codex.toml False
test ! -e ~/.codex/agents/coordinator.toml && echo no-symlinked-role
ls ~/.agents/skills/{herdr,herdr-operations,agent-handoff}/SKILL.md
herdr status --json | jq .server.running             # true
herdr --machine acer-swift agent list                # acer reachable through the saved machine
cd ~/claude-code-skills && devenv tasks run herdr:inventory --show-output   # one devenv task runs
```

Then one conversation in each harness. Claude Code: "ask the coordinator what
my agents are doing", which must delegate to the `coordinator` subagent. Codex,
non-interactively and with no `-m` (the account default model applies):

```sh
cd ~/claude-code-skills && codex exec "Spawn the coordinator agent and have it run only coord:brief; reply with hosts_total and answered_hosts" 2>&1 | tee /tmp/codex-coordinator.log
grep -c 'agent type is currently not available' /tmp/codex-coordinator.log      # 0
grep -l 'agent_type.\{0,6\}coordinator' $(ls -t ~/.codex/sessions/*/*/*/rollout-*.jsonl | head -3)   # the parent session
```

Pass: exit 0, the reply carries both numbers, no "currently not available",
and the spawn names `agent_type` `coordinator` rather than falling back to
`default`. acer has no Codex login, so this conversation is the first live
proof; acer checked the mechanism against the 0.162.1 source (#115).

Both adapters read `ROLE.md` from `~/claude-code-skills`, so the role is
whatever that checkout holds; keep it at the pinned revision. Codex's
custom-agent schema cannot restrict tools per agent: the Claude adapter
disallows Edit/Write, the Codex coordinator inherits Codex's own sandbox and
approval settings and is bounded by its instructions only.

On acer-swift:

```sh
test ! -e ~/.claude/agents/coordinator.md && test ! -e ~/.codex/agents/coordinator.toml && echo worker-ok
ls ~/.claude/agents/quality.md
herdr status --json | jq .server.running             # true
```

## Wake-up timer (lenovo only)

`sam.herdr.coordinatorWakeup.enable` installs the user units
`coordinator-wakeup.timer` and `.service`. Every `interval` (2min) of service
inactivity the service runs `devenv tasks run coord:changed` in
`~/claude-code-skills`; the task is a jq diff of Herdr agent state, GitHub
counts and the audit log's open handoffs against
`~/.local/state/coordinator/changed/snapshot.json` and prints nothing when
nothing is actionable. Only then does the service start one headless
`claude -p --agent coordinator --max-budget-usd <maxBudgetUsd>` session,
write its report to `~/.local/state/coordinator/changed/wake-<ts>.md` and
raise a Herdr toast. The session runs `--permission-mode dontAsk` with an
allow list of the role's read tasks and Herdr's read commands (the act tasks,
`herdr --machine`, `gh`, `git push` and file edits are denied as well), so
it can only read and report. Lines are appended to `changed/pending.txt`
first and cleared only when the session exits 0; after two failed sessions
in a row they are parked in `changed/pending.failed` (toast raised) and no
further session starts until the owner clears that file, so a persistent
failure cannot buy a session every tick. A checkout without the task yet (the skills PR
not merged or not pulled) is logged and skipped, not failed.

```sh
systemctl --user list-timers coordinator-wakeup.timer
journalctl --user -u coordinator-wakeup.service -n 20 --no-pager
cat ~/.local/state/coordinator/changed/latest.json | jq .changes
```

Switch it off without a rebuild with
`systemctl --user disable --now coordinator-wakeup.timer` (the next switch
re-enables it); for good, set `sam.herdr.coordinatorWakeup.enable = false`
on lenovo. Nothing else in this module touches a worker.

## Rollback

Each switch is one NixOS generation; Home Manager's files roll back with it.

```sh
# lenovo
sudo nixos-rebuild switch --rollback     # or pick the previous entry at boot (systemd-boot)

# acer-swift: deploy-rs rolls back by itself when the confirm step fails; otherwise
ssh -t acer-swift sudo nixos-rebuild switch --rollback          # from a real terminal (lukas's sudo password)
ssh deploy@acer-swift sudo nixos-rebuild switch --rollback      # or as deploy, from lenovo only (passwordless sudo)
```

Rolling back also returns the skills input to `08e300a` on that host. The
writable `~/claude-code-skills` checkout is not part of the generation: leave it
at `2704cd0` (only the coordinator's tasks read it) or check out `08e300a` there
too if the rollback is about the role itself. The
Herdr saved-machine list (`~/.local/state/herdr/client/endpoints.json`) is not
touched by this change and needs no rollback.
