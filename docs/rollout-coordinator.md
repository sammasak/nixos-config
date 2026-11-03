# Coordinator rollout: lenovo coordinates, acer executes

**Status: prepared, WAITING FOR OWNER DEPLOY APPROVAL.** Nothing here has been
switched on either host. Tracking: #111, sammasak/skills#28.

## What changes

| Host | Claude Code | Codex |
|---|---|---|
| lenovo (coordinator: declares `sam.herdr.machines`) | `~/.claude/agents/coordinator.md` from the skills input | `~/.codex/agents/coordinator.toml`, built from the pinned `agents/coordinator/ROLE.md` (`mission` is the description, the file is `developer_instructions`); the role's skills `herdr`, `herdr-operations`, `agent-handoff` added to `~/.agents/skills` and `~/.codex/skills` |
| acer-swift (worker) | every adapter except `coordinator.md`; all shared skills | unchanged (portable skills) |

Both hosts move the skills input to `fdbc501`, so every linked skill and
adapter follows it. gh, herdr and devenv are already on both hosts. No package,
service, timer or daemon is added: the system and user unit lists of both
toplevels are identical to main's, and `nix store diff-closures` against main
shows only the skills source and, on lenovo, `codex-coordinator-agent.toml`.

## Exact revisions (built on acer-swift, 2026-11-03)

| | Value |
|---|---|
| nixos-config base | `ad233f30` (main) |
| skills input | `fdbc501165d276547fdab7ffeffe64e3be5e0813` (was `08e300a`), narHash `sha256-k/j1j7DzvZuma8kCOA+inZuxbPRej/Ho7NlwXiK6tjI=` |
| lenovo toplevel | `/nix/store/m23cllh7w1bz23vbi35h7ly2rgizrpd8-nixos-system-lenovo-21CB001PMX-26.11.20261015.fe13242` (main: `f1i5flr4…`) |
| acer-swift toplevel | `/nix/store/70amrwmhfw9mjfjlisagfhg85sk1bs77-nixos-system-acer-swift-26.11.20261015.fe13242` (main: `kwz7y983…`) |
| Codex adapter | `/nix/store/8l72p3bqikrw2b37n2pqgs5jl30aqr2m-codex-coordinator-agent.toml` |

The toplevel hashes hold for the PR head that was built; a later commit on the
branch or a rebase changes them, so rebuild and compare before switching.

## Before switching

- Park agent sessions on the host: a switch breaks the Bash tool of every
  running Claude Code session there (stale shell snapshots).
- On lenovo, make the writable skills checkout match the pin, because the
  coordinator's tasks run from it, not from the store:
  `git -C ~/claude-code-skills fetch && git -C ~/claude-code-skills status -sb`
  then bring `main` to `fdbc501` (or later) without discarding local work.
- `just diff` on each host: expect no bootloader or kernel store-path change.

## Switch (owner)

Lenovo first, then acer:

```sh
# on lenovo, in ~/nixos-config at the merged commit
just switch                 # nixos-rebuild switch --install-bootloader for .#lenovo

# then, from lenovo
just deploy-acer            # deploy-rs, magic rollback if acer stops answering
```

## Validate

On lenovo:

```sh
readlink -f ~/.claude/agents/coordinator.md          # .../<skills fdbc501 source>/agents/coordinator.md
python3 -c 'import tomllib,sys; d=tomllib.load(open(sys.argv[1],"rb")); print(d["name"])' ~/.codex/agents/coordinator.toml
ls ~/.agents/skills/{herdr,herdr-operations,agent-handoff}/SKILL.md
herdr status --json | jq .server.running             # true
herdr --machine acer-swift agent list                # acer reachable through the saved machine
cd ~/claude-code-skills && devenv tasks run herdr:inventory --show-output   # one devenv task runs
```

Then one conversation in each harness. Claude Code: "ask the coordinator what
my agents are doing", which must delegate to the `coordinator` subagent. Codex:
"have the coordinator report what my agents are doing", which must spawn the
custom agent `coordinator` (`/subagents` shows it). That Codex conversation is
the first proof that Codex loads the generated file; acer could only check it
against Codex's documented schema.

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
ssh acer-swift sudo nixos-rebuild switch --rollback   # needs a real terminal for sudo
```

Rolling back also returns the skills input to `08e300a` on that host. The
Herdr saved-machine list (`~/.local/state/herdr/client/endpoints.json`) is not
touched by this change and needs no rollback.
