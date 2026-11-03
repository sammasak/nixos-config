# Coordinator rollout: lenovo coordinates, acer executes

**Status: prepared, WAITING FOR OWNER DEPLOY APPROVAL.** Nothing here has been
switched on either host. Tracking: #111, sammasak/skills#28.

## What changes

| Host | Claude Code | Codex |
|---|---|---|
| lenovo (coordinator: declares `sam.herdr.machines`) | `~/.claude/agents/coordinator.md` from the skills input | `~/.codex/agents/coordinator.toml`, the skills input's `agents/coordinator/codex.toml` installed as shipped (its instructions point Codex at `agents/coordinator/ROLE.md`); the role's skills `herdr`, `herdr-operations`, `agent-handoff` added to `~/.agents/skills` and `~/.codex/skills` |
| acer-swift (worker) | every adapter except `coordinator.md`; all shared skills | unchanged (portable skills) |

Both hosts move the skills input to `309e7e7` (skills main after #32 and #34), so every linked skill and
adapter follows it. gh, herdr and devenv are already on both hosts. No package,
service, timer or daemon is added: the system and user unit lists of both
toplevels are identical to main's, and `nix store diff-closures` against main
shows only the skills source and, on lenovo, the coordinator file links.

## Exact revisions (built on acer-swift, 2026-11-03)

| | Value |
|---|---|
| nixos-config base | `be1f01a6` (main, after #112) |
| skills input | `309e7e7eb7d20cedc0e3723903567c3dc32d73b1` (hosts run `08e300a` today), narHash `sha256-YkQy17yN+BnFBIbo+PH9TzdZLFJUPtrj5SMXT6jd0Bk=` |
| lenovo toplevel | `/nix/store/vrpl51lgmm1glgbwa98m0432yk8w1ila-nixos-system-lenovo-21CB001PMX-26.11.20261015.fe13242` (main: `83l2hqij…`) |
| acer-swift toplevel | `/nix/store/10xvx80a2kgwgzc2qijjikxwnr6zkf1w-nixos-system-acer-swift-26.11.20261015.fe13242` (main: `70amrwmh…`) |
| Codex adapter | `/nix/store/vfw0l954s5mb5zjkirah1blpa8b7y21x-source/agents/coordinator/codex.toml` |

The toplevel hashes hold for the PR head that was built; a later commit on the
branch or a rebase changes them, so rebuild and compare before switching.

## Before switching

- Park agent sessions on the host: a switch breaks the Bash tool of every
  running Claude Code session there (stale shell snapshots).
- On lenovo, make the writable skills checkout match the pin, because the
  coordinator's tasks run from it, not from the store:
  `git -C ~/claude-code-skills fetch && git -C ~/claude-code-skills status -sb`
  then bring `main` to `309e7e7` (or later) without discarding local work.
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
readlink -f ~/.claude/agents/coordinator.md          # .../<skills 309e7e7 source>/agents/coordinator.md
python3 -c 'import tomllib,sys; d=tomllib.load(open(sys.argv[1],"rb")); print(d["name"])' ~/.codex/agents/coordinator.toml
ls ~/.agents/skills/{herdr,herdr-operations,agent-handoff}/SKILL.md
herdr status --json | jq .server.running             # true
herdr --machine acer-swift agent list                # acer reachable through the saved machine
cd ~/claude-code-skills && devenv tasks run herdr:inventory --show-output   # one devenv task runs
```

Then one conversation in each harness. Claude Code: "ask the coordinator what
my agents are doing", which must delegate to the `coordinator` subagent. Codex:
"have the coordinator report what my agents are doing", which must spawn the
custom agent `coordinator` (once spawned, `/subagents` lists its thread). That Codex conversation is
the first proof that Codex loads the shipped file; acer could only check it
against Codex's documented schema.

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
at `309e7e7` (only the coordinator's tasks read it) or check out `08e300a` there
too if the rollback is about the role itself. The
Herdr saved-machine list (`~/.local/state/herdr/client/endpoints.json`) is not
touched by this change and needs no rollback.
