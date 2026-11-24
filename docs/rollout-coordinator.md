# Coordinator on lenovo: wake-up, delegation and git auth

## What the coordinator adapter installs

| Host | Claude Code | Codex |
|---|---|---|
| lenovo (coordinator: declares `sam.herdr.machines`) | `~/.claude/agents/coordinator.md` from the skills input | `[agents.coordinator] config_file` in `~/.codex/config.toml`, pointing at the skills input's `agents/coordinator/codex.toml` (a regular store file: Codex re-reads it with `O_NOFOLLOW` at spawn, so it is never symlinked into `~/.codex/agents`); its instructions point at `agents/coordinator/ROLE.md`; the skills named in ROLE.md are added to `~/.agents/skills` and `~/.codex/skills` |
| every other host | every adapter except `coordinator.md` | no coordinator agent, no coordinator skills |

Both adapters read `ROLE.md` from the writable `~/claude-code-skills` checkout, so the role is whatever that
checkout holds. The Claude adapter disallows Edit and Write; Codex's custom-agent schema cannot restrict tools per
agent, so the Codex coordinator is bounded by its instructions and Codex's own sandbox. The wiring is pinned by
`scripts/test-coordinator-wiring.py`.

## Wake-up timer (lenovo only)

`sam.herdr.coordinatorWakeup.enable` (options in `modules/core/agent-options.nix`, unit in
`modules/programs/cli/coordinator-wakeup.nix`) installs the user units `coordinator-wakeup.timer` and `.service`, the
`platform-delivery-record` timer (06:30), plus the report timers `coordinator-report-daily` (03:00,
`coord:report:daily` for yesterday) and `coordinator-report-fortnight` (Mondays 07:00; on even ISO weeks it renders
`coord:report:weekly` for each week since the previous even week, that one included; on odd weeks it does nothing). A
host without `sam.herdr.machines`, or a worker, fails evaluation with it on. Every `interval` (default 2min) of
service inactivity the service runs `devenv tasks run coord:changed --input-json '{"consume":true}'` in
`~/claude-code-skills`; the task diffs Herdr agent state, GitHub counts and the audit log's open handoffs against a
snapshot under `~/.local/state/coordinator/changed/` and prints nothing when nothing is actionable. Only then does
the service start one headless `claude -p --agent coordinator --max-budget-usd <maxBudgetUsd>` session (default
1.00), write its report to `changed/wake-<ts>.md` and raise a Herdr toast. The session dispatches only as execution
pool sessions (`pool:start`, `pool:send`, `pool:submit`), never to a Herdr pane; the pool acts' label gate stays the
authority for every dispatch (docs/records/execution-pool-contract.md#how-work-is-dispatched).

The session runs `--permission-mode dontAsk`: anything outside its allow list is refused, not asked. The allow list is
pinned word for word by `scripts/test-coordinator-wiring.py`:

| Allowed | Form | What it reaches |
|---|---|---|
| `coordinator-read` | `coordinator-read <task> ['<input-json>']` | `coord:brief` (prints `brief/latest.md`), `coord:changed` (never consuming), `gh:work`, `gh:repos`, `git:recent`, `harness:session-summary`, `pool:status`, `pool:result`, `pool:wait` |
| `coordinator-act` | `coordinator-act <task> '<input-json>'` | `pool:start`, `pool:send`, `pool:submit`, `gh:label`, `gh:comment`; one non-empty object, no other argument; `gh:comment` and `gh:label` only with `repo` under the owner's account (`sam.userConfig.git.userName/<repo>`); `coord:spawn`, `coord:handoff` and `herdr:message` are not reachable |
| `cd` | into `~/claude-code-skills` | |
| `Read` | the checkout and `~/.local/state/coordinator/` | |

The unattended session acts under ROLE.md's Autonomy rule: no confirmation per dispatch (owner decision,
sammasak/skills#28). A pool task cannot merge (the slots' GitHub proxy has no merge route), so a head graded 9 or
more goes in the report for the owner.

## Owner skills config

The owner's skills config for the host is `sam.herdr.coordinatorWakeup` (`mayApprove`, `approvalDecision`, `panes`,
`interactiveQuietSeconds`, `poolHost`, required). `mayApprove` requires `approvalDecision`, the URL of a comment on one of the owner's own
issues quoting the decision. The timer and the devenv wrappers append the config to every devenv call as fixed
`--option` flags (`coordinator.mayApprove`, `.approvalDecision`, `.panes`, `.interactiveQuietSeconds`, `.poolCommand`); the caller
passes none, so a session can neither widen the delegation nor drop the pane rule. Home Manager also renders
`mayApprove`, `approvalDecision`, `panes` and `poolCommand` as `~/claude-code-skills/devenv.local.nix` (a store symlink, untracked:
do not `git add` it), which devenv reads next to `devenv.nix`, so an interactive Coordinator running devenv in the
checkout sees the same delegation and pane list. Consequences:

- Any session that runs `gh:label` in that checkout holds the same delegation, still bounded by the skills gate (the
  owner's open issues a worker can finish, never a PR, never one carrying `needs-live`, `blocked` or `needs-decision`,
  the decision cited). Withdraw it with `mayApprove = false` plus a switch:
  the send gate then refuses every label added under it.
- A command-line `--option` wins over the file, which is why the timer's flags agree with it. The skills test suites
  read the file too, so they pin their own delegation defaults with a leading `--option` (sammasak/skills#59).
- A checkout older than the pinned skills input fails every call with "option ... does not exist"; the timer reports
  "older than the pinned skills input", exits 1 and toasts once. Pull the checkout.

`panes` names the interactive Coordinator's own pane, which `coord:changed` never counts as a worker and
`coord:handoff`/`herdr:message` refuse as a target. `interactiveQuietSeconds` suppresses wake sessions while such a
pane worked within that many seconds. `nixos:delegation-test` (`scripts/test-coordinator-delegation.py`) runs the
generated file against the pinned skills input with a fake `gh`: `gh:label approved` on an owner issue is accepted
with the decision on both audit lines, and refused as `not_delegated` when the file says `mayApprove = false`.

## Denied, audit, auth, lock, pending

Denied, and refused rather than asked: `devenv` itself (a free `--option` would swap `poolCommand` or `ghCommand`),
every `herdr` command, `gh`, `git`, `ssh`, `sudo`, `Edit`, `Write`,
`NotebookEdit`, and every shell write primitive and interpreter, since none is on the allow list. Each act lands in
`~/.local/state/coordinator/audit.jsonl` through its task (an attempt line before, an outcome line after).

The session authenticates with the OAuth token file the Fish session also exports (`/run/secrets/claude_oauth_token`),
else `~/.claude/.credentials.json`; with neither it does not start and toasts. The lock fd never reaches a child, and
a lock (`session.lock`) still held after 20 s fails the run (exit 75) with a toast. Lines are appended to
`changed/pending.txt` first and cleared only when the session exits 0; after two failed sessions in a row they are
parked in `changed/pending.failed` (toast raised) and no further session starts until the owner clears that file. A
checkout without the task is logged and skipped, not failed.

A tick that starts no session logs why, once: `no session: fleet idle with N work item(s) left; the idle line already
printed at <time> for this fleet+work fingerprint, so no new session until the fleet or the work changes`, `no session:
wake budget deferred (<reason>) until <time>`, `no session: fleet idle; the idle check was skipped: ...` (gh failed),
`no session: fleet idle (...), no work left` or `no session: fleet not idle (...); no actionable change`. The reason is
remembered in `changed/quiet.last` and repeated only when it changes or after a session.

```sh
systemctl --user list-timers coordinator-wakeup.timer
journalctl --user -u coordinator-wakeup.service -n 20 --no-pager
cat ~/.local/state/coordinator/changed/latest.json | jq .changes
```

### Switching it off

Without a rebuild: `systemctl --user disable --now coordinator-wakeup.timer` (the next switch re-enables it). For
good: set `sam.herdr.coordinatorWakeup.enable = false` on lenovo. Nothing else in this module touches a worker.

### Rollback

Each switch is one NixOS generation; Home Manager's files roll back with it. `--no-reexec` is required: without it
nixos-rebuild re-executes itself from `<nixpkgs/nixos>`, which these flake-only hosts lack, and changes nothing
(README.md).

```sh
# lenovo
sudo nixos-rebuild switch --rollback --no-reexec     # or pick the previous entry at boot (systemd-boot)

# acer-swift: deploy-rs rolls back by itself when the confirm step fails; otherwise
ssh -t acer-swift sudo nixos-rebuild switch --rollback --no-reexec          # from a real terminal (lukas's sudo password)
ssh deploy@acer-swift sudo nixos-rebuild switch --rollback --no-reexec      # or as deploy, from lenovo only (passwordless sudo)
```

Rolling back also returns the skills input on that host. The writable `~/claude-code-skills` checkout is not part of
the generation (only the coordinator's tasks read it): check out the matching revision there too if the rollback is
about the role itself. The Herdr saved-machine list (`~/.local/state/herdr/client/endpoints.json`) is not part of the
generation either.

## Git authentication from lenovo

Git over SSH on lenovo authenticates with the key file `~/.ssh/id_ed25519` (no passphrase), which OpenSSH tries
by name without any agent. The agent behind `SSH_AUTH_SOCK` is gpg-agent (`programs.gnupg.agent.enableSSHSupport` in
`modules/core/system.nix`); it holds no identities (`~/.gnupg/sshcontrol` is empty), so `ssh-add -l` answering "The
agent has no identities" is the normal state, and a rebuild restarting the agent changes nothing for git. Not worth
changing: `AddKeysToAgent yes` would import the key, but gpg-agent then asks through pinentry, which hangs a headless
session.

When GitHub's SSH endpoint misbehaves but HTTPS works, push with gh's token without touching the remote or the key;
the capital S in `Sammasak` dodges the `url."git@github.com:sammasak/"` rewrite in
`modules/programs/cli/git/default.nix`, and the pre-push hooks run as usual:

```sh
git -c credential.helper='!gh auth git-credential' push https://github.com/Sammasak/<repo>.git HEAD:refs/heads/<branch>
```

The rollout plan and its acceptance record: `git log -- docs/rollout-coordinator.md`.
