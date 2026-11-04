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
inactivity the service runs `devenv tasks run coord:changed --input-json '{"consume":true}'` in
`~/claude-code-skills`; the task is a jq diff of Herdr agent state, GitHub
counts and the audit log's open handoffs against
`~/.local/state/coordinator/changed/snapshot.json` and prints nothing when
nothing is actionable. Only then does the service start one headless
`claude -p --agent coordinator --max-budget-usd <maxBudgetUsd>` session,
write its report to `~/.local/state/coordinator/changed/wake-<ts>.md` and
raise a Herdr toast. The session runs `--permission-mode dontAsk` and acts
under ROLE.md's Autonomy rule without a human (owner decision on
sammasak/skills#28: everything except sudo, and merges are not asked of the
owner; the label gate inside `herdr:message` stays the authority for every
send). Its allow list, pinned word for word by
`scripts/test-coordinator-wiring.py`, is:

| Allowed | Form | What it reaches |
|---|---|---|
| `coordinator-read` | `coordinator-read <task> ['<input-json>']` | the role's read tasks: `coord:brief` (prints `brief/latest.md`, never devenv's stdout), `coord:changed` (never consuming), `coord:capacity`, `work:status`, `herdr:inventory`, `herdr:inspect`, `herdr:await`, `gh:work`, `gh:repos`, `git:recent`, `harness:session-summary` |
| `coordinator-act` | `coordinator-act <task> '<input-json>'` | `coord:handoff`, `herdr:message`, `gh:label`, `gh:comment`; one non-empty object, no other argument; `gh:comment` and `gh:label` only with `repo` under the owner's account (`sam.userConfig.git.userName/<repo>`); `coord:spawn` is not reachable |
| `coordinator-prompt` | `coordinator-prompt [--machine <label>] <agent_id> /clear\|/compact` | `herdr agent prompt` with exactly that literal text (a worker's hygiene prompt); identifiers never start with a dash, so none becomes a herdr flag; each call is logged in `~/.local/state/coordinator/prompts.log` |
| Herdr reads | `herdr machine list\|status`, `herdr agent list\|get\|read\|wait` | as typed; the `herdr --machine` deny is textual, so the trailing `--machine <label>` form of these read commands still reaches a saved machine (read-only) |
| `cd` | into `~/claude-code-skills` | |
| `Read` | `//home/lukas/claude-code-skills/**`, `//home/lukas/.local/state/coordinator/**` | the checkout and the coordinator state, `//` (filesystem-root) anchors |

The owner's skills config for the host is `sam.herdr.coordinatorWakeup`
(`mayApprove`, `approvalDecision`, `panes`). The timer and the two devenv
wrappers append it to every devenv call as fixed `--option` flags
(`coordinator.mayApprove`, `coordinator.approvalDecision`,
`coordinator.panes`), pinned word for word by the wiring test; the caller
still passes none, so a session can neither widen the delegation nor drop
the pane rule, and nothing in the checkout changes (an interactive
Coordinator session running devenv itself sees the skills defaults). On
lenovo `mayApprove = true` with the owner's decision comment
(sammasak/skills#28, quoted: "change so that you are allowed to set approved
label!!") lets the wake session's `gh:label` add `approved` to one of the
owner's open issues that a worker can finish (never a PR, never over
`needs-live`, `blocked` or `needs-decision`); both audit lines cite the
decision and `herdr:message` accepts that label on that basis.
`panes = [ "lenovo-21CB001PMX/wM:p1" ]` names the interactive Coordinator's
pane, which `coord:changed` then never counts as a worker and
`coord:handoff`/`herdr:message` refuse as a target (skills#54). Withdrawing
the delegation is `mayApprove = false` plus a switch: the send gate then
refuses every label the Coordinator added under it. Rollout order: pull the
checkout first (the options exist since skills `f958d38`), then switch; a
checkout older than the pin fails every call with "The option
`coordinator.panes' does not exist", which the timer reports as "older than
the pinned skills input" with the pull command, exits 1 and toasts.

Denied, and refused rather than asked: `devenv` itself (a free `--option`
would swap `herdrCommand` or `ghCommand`), `herdr agent prompt|send-keys|start`,
`herdr --machine`, `herdr pane`, `gh`, `git`, `ssh`, `sudo`, `Edit`, `Write`,
`NotebookEdit`, and every shell write primitive and interpreter (`tee`, `sed -i`,
`bash -c`, `python`) since none is on the allow list; the file readers Claude
Code path-checks against the Read rules (`cat`, `head`, `tail`) reach only the
two Read scopes, and `jq` is refused. Each act lands in
`~/.local/state/coordinator/audit.jsonl` through its task (an attempt line
before, an outcome line after), so a wake session that sent a handoff leaves
`herdr:message` attempt and outcome records naming its `handoff_id`,
`authorized_by` and `audit_id`. The session authenticates with the
OAuth token file the Fish session also exports
(`/run/secrets/claude_oauth_token`), else `~/.claude/.credentials.json`; the
journal names the source. The lock fd never reaches a child, and a lock still
held after 20 s fails the run (exit 75) with a toast. Lines are appended to `changed/pending.txt`
first and cleared only when the session exits 0; after two failed sessions
in a row they are parked in `changed/pending.failed` (toast raised) and no
further session starts until the owner clears that file, so a persistent
failure cannot buy a session every tick. A checkout without the task yet (the skills PR
not merged or not pulled) is logged and skipped, not failed.

A tick that starts no session logs why, once: `no session: fleet idle with N
work item(s) left; the idle line already printed at <time> for this
fleet+work fingerprint, so no new session until the fleet or the work
changes`, `no session: wake budget deferred (per_hour_cap) until <time>`,
`no session: fleet idle; the idle check was skipped: …` (gh failed) or
`no session: fleet not idle (…); no actionable change`. The reason is
remembered in `changed/quiet.last` and repeated only when it changes or
after a session, so a ten-hour idle stretch is one journal line, not 300
silent ticks (the overnight no-wake of 2026-11-03/04 on skills#28 had no
such line: the one idle wake at 23:04 CET went to the read-only profile,
sent nothing, and the unchanged fingerprint rightly suppressed repeats).

```sh
systemctl --user list-timers coordinator-wakeup.timer
journalctl --user -u coordinator-wakeup.service -n 20 --no-pager
cat ~/.local/state/coordinator/changed/latest.json | jq .changes
```

Switch it off without a rebuild with
`systemctl --user disable --now coordinator-wakeup.timer` (the next switch
re-enables it); for good, set `sam.herdr.coordinatorWakeup.enable = false`
on lenovo. Nothing else in this module touches a worker.

### Lenovo switch record (2026-11-03)

Switched with `just deploy-lenovo` from main `39c1b81` (deploy-rs loopback,
"Deployment confirmed", 78 s): `/run/current-system` is
`/nix/store/z37xik30qzmw6qy4pq1l4xzgvyqvql6j-nixos-system-lenovo-21CB001PMX-26.11.20261015.fe13242`;
kernel, initrd and systemd unchanged against the previous generation
(`sz1lw0qp…`). `coordinator-wakeup.timer` enabled and active, `Linger=yes`.
The first tick ran at activation (the elapsed `OnBootSec`), found two real
changes and finished its session in 39 s. Rollback stays
`sudo nixos-rebuild switch --rollback` (owner) or
`systemctl --user disable --now coordinator-wakeup.timer` until the next switch.

## Git authentication from lenovo (checked 2026-11-04)

Git over SSH on lenovo authenticates with the key file
`~/.ssh/id_ed25519` (no passphrase; GitHub key "lenovo", added
2026-01-14), which OpenSSH tries by name without any agent. The agent
behind `SSH_AUTH_SOCK` is gpg-agent (`programs.gnupg.agent.enableSSHSupport`
in `modules/core/system.nix`, socket `/run/user/1000/gnupg/S.gpg-agent.ssh`,
also the target of herdr's `herdr.sock.agent` link); it holds no identities
and never did (`~/.gnupg/sshcontrol` is empty), so `ssh-add -l` answering
"The agent has no identities" is the normal state, not a fault, and a
rebuild restarting the agent changes nothing for git. The push failures of
2026-11-04 09:58–10:45Z ("Permission denied (publickey)" with the same key
that GitHub accepts before and after) fell inside GitHub's incident
"Incident with Pull Requests, Git Operations and Issues" (opened 09:49:55Z,
API 502s in the same window), not the 09:22 CET switch.

When GitHub's SSH endpoint misbehaves but HTTPS works, push with gh's token
without touching the remote or the key (the capital S dodges the
`url.git@github.com:sammasak/.insteadOf` rewrite in `~/.config/git/config`;
the pre-push hooks run as usual):

```sh
git -c credential.helper='!gh auth git-credential' push https://github.com/Sammasak/<repo>.git HEAD:refs/heads/<branch>
```

Not worth changing: `AddKeysToAgent yes` would import the key into
gpg-agent on first use, but gpg-agent then asks through pinentry to protect
the imported key, which hangs a headless session; HTTPS-only is not
intended either. Nothing in this section touches a secret.

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
