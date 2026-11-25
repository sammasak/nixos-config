# ADR: Execution pool contract (v0.1, #649)

Status: proposed with #649's PR, for the owner to accept by merging. Epic: #646. This record freezes the data contract
and the owners; it adds no daemon, database, socket, port, Nix option or host change.

## Owners

| Concern | Owner | Where |
|---|---|---|
| Static slot capacity (how many reusable nspawn slots a host declares, their closure, cgroups, egress) | NixOS `homelab.execPool` into `services.devEnvironments`, changed only by a reviewed deploy | `modules/workers/core.nix`, `modules/workers/default.nix`, `modules/workers/execution-pool.nix` |
| Task and attempt state (queued to terminal, leases, epochs, idempotency keys) | the queue (#651, PostgreSQL) | `pkgs/exec-pool/src/queue.rs`, CLI `exec-pool-queue`; on acer (`modules/homelab/exec-pool.nix`) |
| Slot assignment on a host (claim, start, stop, sanitise, resource accounting) | a host-local runner (#652) | `pkgs/exec-pool/src/runner.rs`, `exec-pool-runner`; `modules/homelab/exec-pool-runner.nix`, on acer and msi, one per slot |
| The inner tool loop | the native Claude, Codex and Pi CLIs, unchanged | `docs/herdr.md` |
| Viewing sessions | Herdr: a session turn's agent is in its slot's pane, never the source of queue truth | `docs/herdr.md` |
| Power windows and placement facts | `sam.fleet.hosts.*` | `modules/core/fleet.nix` |

A task is not a container, a deploy, a Herdr pane or a CLI session. Workers hold no queue credential and no host
privilege.

## Contract

`pkgs/exec-pool` (a library, built and tested by `nixos:exec-pool-test`) defines `TaskSpec`, `Attempt`, `Slot`,
`CheckpointRef` and `Receipt`. Each carries `schema_version` (1). Another version, or a workdir that is empty,
absolute, holds `..` or NUL, does not deserialise. `validate()` then rejects, per record, the identifiers it names as
empty (for a task also an empty `argv`), a task capability outside the granted set, and an attempt whose placement
disagrees with its status (required while leased, running or checkpointing, absent while queued or waiting). Every
record rejects unknown fields, so no token, secret or credential can ride along: a task names a `credential_class`
the host resolves. `TaskSpec::fits` admits a slot only when it is idle, offers the task's agent and capabilities and equals
every pin the task sets (`runner_version`, `nix_closure_digest`, `agent_version`, `skill_revision`, reserved for #657).
`CheckpointRef` names where a parked session's work is on its remote: `uri` the repository and full ref name, `digest`
the commit (`absent` before anything was pushed) and `generation` the lease epoch that parked it. It names no host.

States (`pkgs/exec-pool/src/state.rs`, snake_case on the wire):

```text
queued -> leased -> running -> checkpointing -> waiting | queued | succeeded | failed | needs_review | cancelled
waiting -> queued            (a wake: for a session task, a message in its inbox)
leased  -> queued            (lease expired before its start was accepted)
running | checkpointing -> needs_review   (lease expired: effects unknown, never replayed blindly)
needs_review -> succeeded | failed | queued   (resolve: an operator's explicit decision, never automatic)
queued | waiting -> cancelled                 (cancel_task; a live attempt is marked and its runner stops it)
any return to queued with no attempt left -> failed
```

One `Attempt` id spans every lease of that attempt, told apart by the epoch, which is why a `Receipt` is keyed by
attempt and epoch. A lease and an expiry bump the monotonic lease epoch. Every event names the epoch it was decided on
and one that is not current is rejected, so a holder whose lease expired cannot complete and a re-delivered lease
cannot land twice; an expired lease is reconciled rather than handed to a duplicate attempt. That needs one rule of
the runner (#652): it begins no work before its `start` is accepted, so `leased -> queued` is only ever a lease that
ran nothing. An attempt's placement (host, slot) is cleared on `queued` and `waiting` and kept on `needs_review` for
review. Delivery is **at-least-once**: a resubmission under the same idempotency key returns the task already queued,
a different task under that key is refused, and no external effect (a GitHub mutation included) is claimed
exactly-once. A `Receipt` lists the effects an attempt reports, for reconciliation; it counts only with the `settle`
accepted at its lease epoch: `Receipt::settles` checks the task, attempt, epoch and outcome against the attempt the
settle left, and only a settle to succeeded, failed or needs_review takes one (and must). Every lease but one that
parks in `waiting` counts against `retry.max_attempts` (at least 1), so an expiring lease cannot loop. `TaskSpec`,
`Attempt`, `Slot` and `Receipt` each have a `parse()` that reads the version before any other field.

### Sessions, turns, park and wake (#656)

A task with `tasks.session` (queued by `exec-pool start`; the queue's side is under Sessions below) is a session: one
agent session (its id the queue's `session_uuid`) that lives across
leases. Each lease is one **turn**, and a turn ends in a **park** to `waiting`, never in a settle: `turn_end` when the
agent finished its turn, `turn_error` when its call failed or left no verdict, `turn_timeout` when it was stopped at
the turn's time limit, `waiting_until` when it finished and asked for a timer (later also `host_draining`,
`preempted`). A failed turn never fails the session. The time limit is `homelab.execPool.timeoutSecs`
(default 1800 s, the same bound as a one-shot run). A timed-out turn leaves a `continue` row, so the session resumes
its own transcript in a new turn told to check its last action; the third timeout in a row with no message read
since the first parks with no `continue` row and stays in `waiting` until a message. A
**wake** is a row in the task's inbox due: a message (`exec-pool send`) at once, a timer (`exec-pool send --at`, or the
agent's own `pool-wait`) at its `due_at`. It queues the session again, and the next claim carries the turn's input (the task's prompt on the
first turn, the messages since on a later one) and `upto`, the last message it holds, which the park hands back. A
turn with no result, or whose lease was lost, goes to `needs_review` as any run does. The park records the result and
a `CheckpointRef`; any host that fits may claim the next turn. One-shot tasks keep the lifecycle above unchanged.

## Queue (#651)

PostgreSQL over a Unix socket only (`Store::open` refuses a TCP host), so the database's peer authentication is the
caller's. Schema `pkgs/exec-pool/migrations/0001_queue.up.sql`; forward-only in production, with
`exec-pool-queue migrate-down` dropping everything after the operator has exported what they keep. A claim takes the fitting queued
attempt of the highest priority (`tasks.priority`, -100 to 100, set by `submit` and `start --priority N` through
migration 0016, default 0) plus one for every 10 minutes it has waited queued, the oldest among equals, so a low one is
not starved; nothing is preempted. It locks only the queued row it takes, `FOR UPDATE SKIP LOCKED`; every change runs `transition` and then the `attempts_fence` trigger, which refuses
a write that names any epoch but the current one (or none), moves the epoch by more than one, leases from anything
but queued, or touches a succeeded or failed attempt. One live attempt per slot is a unique index. A holder's event
after its lease deadline is refused; `reconcile` (at startup and on a timer) expires overdue leases. A database that
does not answer is `QueueError::Unavailable` (CLI exit 75), never an empty result, and a connection lost during COMMIT is
`QueueError::OutcomeUnknown` (exit 3): read the state (`Store::live_on` for a claim), never replay. The queue holds no GitHub or agent
token: the task's `credential_class` is resolved by the host. Prompt, argv and workdir stay in `tasks`; `events`
holds ids, states and reason codes.

Instrumentation (#658's first slice): every change is one JSON line on stdout, `{"msg":"state_change","change":{
task_id, attempt, lease_epoch, host, slot, from, to, reason, durations: {in_state_ms, since_submit_ms}}}`, and
`exec-pool-queue metrics` renders `exec_pool_queue_up`, `exec_pool_attempts{host,state,agent}`,
`exec_pool_queued_oldest_seconds`, `exec_pool_queued_claimable_oldest_seconds` (the oldest queued attempt whose agent an
idle slot offers), `exec_pool_lease_overdue{host,state}`, `exec_pool_slots{host,state}` (busy, quarantined, idle: polled
in the last two minutes with no lease), `exec_pool_slots_declared{host}` (slots claimed for in the last week), the
histograms `exec_pool_queue_wait_seconds{host,agent}` and `exec_pool_run_seconds{host,agent}` and
`exec_pool_transitions_total{host,from,to,reason}` for a textfile collector; lease expiries are the transitions with
`reason="lease_expired"`. The queue renders every host's series on acer, so `host` is the slot's host from the queue's
rows (an attempt's or session's last lease, a turn's own lease; `none` before any), not the scrape's `node`. Ids, slots
and prompts stay in the log line, never in a label. Each slot's exec helper counts, in its own host's textfile,
`exec_pool_park_push_failures_total{slot}` (a park's push that failed, each try) and `exec_pool_prepare_failures_total{step}`
(a run that failed before its agent: the step's unit, or `admit`, `dock`, `list`, `manifest`, `turn`, `herdr`, `prompt`), split by `node`; such a run's result output is
`prepare failed at <step> (exit N):` and its stderr tail, so `exec-pool result` shows why. When the render fails for any reason it prints only `exec_pool_queue_up 0`
and exits non-zero; the collector installs stdout whatever the exit code, so a missing source reads as absent, not as
zero traffic or as the last good counts.

On acer (`modules/homelab/exec-pool.nix`): database and role `exec_pool` in the host's one PostgreSQL server
(`modules/homelab/postgresql.nix`, which Authentik's database shares), peer over `/run/postgresql` alone; `exec-pool-migrate.service` runs `migrate` at start, and the minutely
`exec-pool-metrics` writes `/var/lib/exec-pool-metrics/exec-pool.prom`, alert ExecPoolQueueDown. The nightly
`exec-pool-backup` dumps the database beside it, on the same disk, like open-webui's backup; nothing copies it off the
host (lenovo pulls Authentik's dump alone, `modules/homelab/authentik-offhost.nix`), which a queue holding real tasks
needs before a runner lands.

## Agent adapter (#655)

`exec_pool::agent::argv(&task)` is what a runner executes in the task's workdir: a `none` task's own argv, or for an
agent task, whose argv is `[prompt]` or `[prompt, model]`, the agent's non-interactive call (`claude -p
--output-format json`, `codex exec`, `pi -p`, unattended as the workers run them, the prompt after `--`) under the
slot's own credentials and egress. `agent::outcome(agent, exit, stdout)` maps the exit to the settle: Claude's final
JSON `is_error` decides for Claude, the exit code for the rest; a signal, or a Claude run with no result, is
`needs_review`. Neither `failed` nor `needs_review` requeues, so no ambiguous external effect is replayed.

## Runner (#652)

`exec-pool-runner-<slot>` (`modules/homelab/exec-pool-runner.nix`, `homelab.execPool`'s `runner` role; on acer for `pool1` to `pool3`, and
on msi for its slots against acer's queue as `exec_pool_runner` over TCP) loops: `reconcile`, `claim` for its slot
(its agents and capabilities; with a poweroff timer only while the claim's hold ends before it), `start`, then
`systemctl start exec-pool-exec@<slot>`, then `checkpoint` and the settle or park, the result recorded
(`Store::record_result`: outcome, exit code, up to 16 KiB of output, the branch), then `dev-env-reset@<slot>`. The lease
is 300 s and the runner renews it every 10 s while the helper runs; each heartbeat reads a cancel its submitter asked
for, and a cancel, or a lease found lost, writes the marker the helper stops the run at. A polkit rule lets `exec_pool`
start those two units of its own slots, and clear the failed state of its reset, and nothing else.

The helper `exec-pool-exec@<slot>` runs as root and has no queue access. It reads the versioned manifest
(`runner::Manifest`: slot, attempt, epoch, task, and a session turn's `session { uuid, input, upto }`) from
`/run/exec-pool-runner/<slot>/`, refusing a symlink, and admits it only to a slot home `dev-env-reset@` replaced since
the last run (`workspace::admit`). In the guest, as its user and through `systemd-run -M`, every step an argv and never
a shell string: a one-shot run makes its workspace `~/attempts/<hex attempt>-<epoch>/{home,work,tmp,out}`, clones
`source.repo` into `work`, checks out `source.rev` (an agent task on `-b pool/<task id>`, with the hand-back rules
before its prompt) and runs `agent::argv(&task)` in `command.workdir` with that HOME and TMPDIR, stopped at
`timeoutSecs`. Before and after, `git ls-remote` of the task's branch tells whether the run handed code back. Up to
1 MiB of each stream and the result go to `/var/lib/exec-pool-exec/<slot>/<hex attempt>-<epoch>/`, kept 30 days.
The agent step's stdout and stderr also go there as they come, its tail kept (`turn_log`: two `agent-<offset>.log`
segments, at most 256 KiB together); the runner puts that tail in the queue's `turn_logs` (migration 0015) at every
heartbeat and once more before the settle or park, so `exec-pool logs ID [-f] [--turn N]` reads a turn, running or
not, from any host, at most 10 s behind. It holds only what the agent printed, which its transcript holds too.

### Session state: the branch, the snapshot, the transcript

A session's durable state is two things, and nothing else of a turn survives its park: its branch `pool/<task id>` and
snapshot ref on the task's remote, and the agent's transcript in the queue. No tree is copied between hosts.

A turn runs in the slot's **dock** `${stateDir}/.sessions/dock/<slot>/cur`, which the guest sees at `/session/cur`
(root-owned 0711, its `home` and `work` the guest user's), the same path in every slot on every host: HOME
`/session/cur/home`, cwd `/session/cur/work/<workdir>`, TMPDIR in the slot home's workspace as for a one-shot run. The
helper makes it afresh each turn (`workspace::Dock`), with the transcript the runner put beside the manifest at
`/session/cur/transcript.jsonl` (0640, the guest's group).

**Resume** (every turn, any host): the guest lists the branch and the snapshot ref on the remote (`git ls-remote`
through the slot's GitHub sidecar), clones the repository into the empty checkout and, by what the listing shows
(`snapshot::Resume`): nothing pushed yet, a new branch at the task's rev; the branch alone, the branch at its commit;
a snapshot, the snapshot fetched, the branch at its parent and the snapshot's tree restored into the working tree only
(`git restore --worktree --no-overlay`), so it reads as uncommitted changes, untracked files included. The remote is
not changed. Then the guest user's current Home Manager files are linked into the empty HOME, the transcript copied to
`$HOME/.claude/projects/<project>/<uuid>.jsonl`, and the agent runs with `--resume <uuid>` when the probe finds it,
`--session-id <uuid>` (and the hand-back rules) when not; a probe that does not finish fails the turn's preparing.

**The agent step.** Interactive Claude as a named worker ran it (`fish -c 'claude $argv'`, Herdr's launcher with the
worker settings, `--dangerously-skip-permissions`, no `-p`), as the step unit `exec-pool-task` inside `dtach -N
/session/cur/home/.exec-pool-agent.sock`; the helper opens a workspace in the host user's Herdr (`pane::label`: the slot
and the task's key) whose pane runs the slot's entry point `<prefix>-<slot> turn`, which attaches to that terminal over
the slot's ssh as `claude`, so Herdr sees and names the agent (`pane::agent_name`: the task id) and the owner watches
and types into it there. Once Claude draws its prompt the helper prompts the turn's input with `herdr agent prompt`
(over 3000 bytes it is written to `/session/cur/home/.exec-pool-input.md` and the prompt names the file). The agent is
idle when Herdr reports it idle or done at a state after the prompt for 5 s (`pane::TurnWatch`). Idle is the session's
**pause**: the agent stays in its pane for `homelab.execPool.idleGraceSecs` (600 s; `idleGraceBusySecs`, 60 s, while a
task is queued and no slot is idle on any host), and whatever the owner types in the pane, or a message `exec-pool send`
puts in the inbox meanwhile (handed over in the turn hint `turn.json` beside the manifest, `runner::TurnHint`, every
heartbeat; the helper prompts it, and the park marks it read), works on in the same turn. Once the grace runs out (at
once when the agent called `pool-wait`) the helper closes Claude with ctrl+c twice and the turn parks as `turn_end`
(`waiting_until` with a timer); its verdict is its transcript's last assistant message (`pane::verdict`). The time
limit counts the agent's work since it was last idle, so a pause never times a turn out, and the helper's unit has no
start timeout of its own; a drain in the pause parks the turn as ended. A prompt that never reached the agent (no new
transcript line), a pane that did not open or Herdr not running parks the session as `turn_error` (failed step
`prompt`, `turn` or `herdr`) with its input **undelivered**: the park marks nothing read and a first turn stays first
(`turns.delivered`, migration 0018), so its next message wakes it with that input again, the task's prompt included.
Mail is prompted only into an agent Herdr calls settled, and marked read only once Herdr took it; a prompt Herdr refused
(a blocked agent) fails the step rather than press Enter into a dialog. Every workspace the turn opened is closed by id
after it. With `homelab.execPool.sessionSurface = "headless"` (no `EXEC_POOL_HERDR`) the turn runs in Claude's print
mode (`claude -p --output-format json`) instead, with no pane and no pause. Before the agent starts the helper writes the
startup dialogs a named worker's home has accepted into the session's `~/.claude.json`.

**Park** (turn end, timeout, drain, cancel of the turn): after the agent's step, the agent having been told on its
first turn and after every later turn's input to commit and push before it stops or waits (`agent::SESSION_PARK`):
1. the transcript is copied out by the guest as its user into the runner's runtime directory (at most 32 MiB);
2. the helper makes a snapshot tree with git plumbing in a scratch index (`read-tree HEAD`, `add --all`,
   `write-tree`): tracked and untracked files, not ignored ones;
3. by `snapshot::plan`: when HEAD is the remote branch's commit and the tree is HEAD's, nothing is left and the
   snapshot ref, if one is there, is deleted; otherwise a snapshot commit on HEAD (`commit-tree`) is pushed to
   `refs/pool-wip/<task id>`, replacing the last park's (`+<commit>:refs/pool-wip/<task id>`). An unpushed commit
   is in the snapshot's history, so it comes back too;
4. the push is tried again with a growing pause for up to 30 minutes (each failure counted,
   `exec_pool_park_push_failures_total`), stopped early by a cancel, not by a drain. A push counts only once a listing
   from outside the checkout (so its config, which the agent may have changed, does not apply) shows the ref at the
   pushed commit, or gone after a delete;
5. the runner parks with the result, the `CheckpointRef` of where the work is, and the transcript (`transcripts`,
   migration 0017: one row per session, lz4 compressed, at most 32 MiB, never older than the stored epoch, removed when
   the session is final). It is never pushed to GitHub: it can hold tool output.

A park whose push did not get through is not a clean park: the turn goes to `needs_review`, its dock stays with its
work and is marked (`/var/lib/exec-pool-exec/<slot>/dock-busy`, which names it), and the runner quarantines the slot
(ExecPoolParkPushFailing, ExecPoolSlotQuarantined). The dock is removed and its mark cleared only once the work is on
the remote, or the turn's agent never ran. A transcript over the bound also sends the turn to review.

The snapshot ref is outside `refs/heads`: it is no branch, so it opens no pull request, starts no CI and is never
merged; a later turn restores it as uncommitted work, which reaches a branch only through the agent's own commit and
push under the repository's hooks. Its push skips the checkout's hooks (`core.hooksPath=/dev/null`): they gate code
bound for a branch. It is the one ref the pool overwrites (`+`), and only that session's. The sidecar passes git's
receive-pack for a listed repository whole, so it limits no ref. The helper marks the dock busy before making it, so
whatever stops it before the close leaves the runner to quarantine the slot rather than reset and reuse it. Known
limits: a guest process outside the step units would keep running in the dock past the turn (none is started);
Codex and Pi run no sessions yet; a needs_review session sent a message before its kept dock was pushed resumes
without that work, and nothing retries a kept dock's push after the park's 30 minutes (an operator pushes it); a
session whose transcript outgrows 32 MiB goes to review at every park; a branch pushed by someone else after the park
is not merged in at the resume (the checkout is the park's, so the agent's next push is refused until it merges); an
untracked nested repository is kept as a gitlink, its files lost, and a file over GitHub's 100 MB limit fails the push. Migration 0017 keeps
floor 9: until every runner host runs this binary, an older runner that claims a session turn finds no tree for its
checkpoint and sends the turn to review (no work lost, nothing replayed); this binary reads an older one's checkpoints
and drops their `hosts`.

Settling a one-shot run (`runner::decide`): a cancel is `cancelled`; a clone or checkout that fails never started the
task's argv, so the attempt goes back to `queued`. A timeout, a guest that went away, or a missing result (or one for
another attempt or epoch) goes to `needs_review`. Otherwise `agent::outcome` decides from the exit code and the
captured stdout. A session turn (`runner::decide_turn`) parks instead on every end of the agent's call, a timeout
included. The command runs as a oneshot unit, so only exit 0 is clean, and systemd-run's 255 (killed by a signal)
counts as no exit code. A helper that finds its attempt's run directory already there refuses to run it again. An
event the queue refuses, or one whose commit is unknown, is never re-sent: the lease expires and `reconcile` decides.
The runner resets the slot at startup (its state then is unknown) and after every run. A reset that fails three times,
or a dock left marked (work not on its remote), writes `/var/lib/exec-pool-runner/<slot>.quarantined` and a row in the queue's
`quarantined_slots` (ExecPoolSlotQuarantined), and that slot is not claimed for again until an operator removes the
marker. Every state change is one JSON line with its ids, and the `run` line carries exit code, output tails,
`claim_to_exec_ms`, `exec_ms`, `prepare_ms` and `run_ms`. `slot_reset` carries `sanitize_ms`. There are no metric
labels but states, agents, reasons and hosts.

A deploy never needs an idle pool: `just deploy` drains a pool host first (`exec-pool-drain on`, the request every
runner reads at `/run/exec-pool-runner/drain`, held until cleared or 2 h pass), so its runners stop claiming and park
a running session turn as `host_draining` with a `continue` row, which wakes it at once on any other host; a one-shot run is not stopped, and a runner restarted under it adopts it. The recipe
waits up to 15 minutes for the host's helpers, deploys, and clears the request whatever deploy-rs returned. A settle
or park the queue cannot take because it is restarting (its own host deployed) is retried while the lease lasts.

## Turning it on

One option set, `homelab.execPool` (`modules/homelab/exec-pool-options.nix`), read by three parts: the slots
(`modules/workers/execution-pool.nix`, on every host through `modules/workers`), the runner
(`modules/homelab/exec-pool-runner.nix`) and the queue (`modules/homelab/exec-pool.nix`, which turns on this host's
PostgreSQL, so it is imported only where the queue runs; it imports the other two).

| Option | Default | What |
|---|---|---|
| `enable` | false | the pool on this host |
| `roles` | `[ ]` | `queue` and/or `runner`; neither: slots alone |
| `slots` | 0 | slots `pool1..poolN` |
| `slot.memory`, `slot.cpu` | `"2G"`, 2 | each slot's reserve |
| `repos` | the owner's repositories | what the GitHub sidecar signs for a slot: fetch, push (branch and snapshot ref), gh |
| `agents` | `[ ]` | `claude`, `codex`, `pi`; sessions run claude |
| `capabilities` | `[ ]` | what each slot offers a task |
| `timeoutSecs` | 1800 | a one-shot run's or a session turn's time limit |
| `queueListener` | null | a runner's remote queue (a `sam.fleet` listener); null: this host's |
| `remoteRunners` | false | the queue admits `exec_pool_runner` over TCP |
| `drainSecs` | 600 | how long before a power window's poweroff (`sam.fleet.hosts.<host>.power`) the runner stops a run |

Refused at evaluation: `queue` in `roles` without `exec-pool.nix` imported, or that module without it; a runner with
no slots or no agents; a runner with the local queue and a `queueListener`, or without both; `remoteRunners` without
the queue; `roles` without `enable`; a slot name another instance uses. A slot holds no credential and no root. The
agent CLIs are the workers' guest packages (`modules/workers/default.nix`), not pool options. A host with the queue and
three slots, and one with four slots claiming from it:

```nix
# the queue host
{
  imports = [ ../../modules/homelab/exec-pool.nix ];
  homelab.execPool = {
    enable = true;
    roles = [ "queue" "runner" ];
    slots = 3;
    agents = [ "claude" ];
    remoteRunners = true;
  };
}
# a runner host
{
  imports = [ ../../modules/homelab/exec-pool-runner.nix ];
  homelab.execPool = {
    enable = true;
    roles = [ "runner" ];
    slots = 4;
    agents = [ "claude" ];
    queueListener = "exec-pool-db";
  };
}
```

## Not `sam.agentRuntime`

The historical `sam.agentRuntime` (#133, #138) made one ephemeral nspawn instance per task with no scheduler; it is
absent on main, its module directory was deleted in #210 (`git show 5a40362 --stat`). The current `modules/workers`
declares long-lived, named instances (`sam.workers.instances`, a `worker-herdr-<name>` unit per agent), each a Nix
deploy. The pool keeps those untouched and adds dynamic work on top of declared slots. `scripts/test-workers-eval.py`
pins it: `homelab.execPool` (#650, `docs/nspawn-workers.md`, Execution pool) unset or off moves no
worker unit, container or toplevel on msi, and a named instance beside the slots keeps its units and its Herdr unit (msi itself declares none since its
named workers were retired).

## Submitting

`exec-pool submit | status | list` (`pkgs/exec-pool/src/bin/exec-pool.rs`, installed beside `exec-pool-queue` on acer)
is how a user without root queues an agent task and watches it. It logs in as `exec_pool_submit`, a role with no
database of its own: `homelab.postgresql.clients` in `modules/homelab/exec-pool.nix` lets the listed system users
(`lukas`; a worker guest's user goes beside it) reach `exec_pool` as that role through a pg_ident peer map, still over
the socket alone, with no password. Migration 0002 gives it no table write: it queues only through `submit_task`, a
SECURITY DEFINER function that takes the one shape `submit` builds (agent claude, codex or pi, an https repo, a rev
that is not an option, a workdir inside the checkout, a prompt and maybe a model; no capability, one attempt,
credential class `slot`) and assigns the task's id from its key, and it reads attempts, events and `task_summaries`,
which leaves out the prompt. So a submitter chooses no policy, forges no event and queues nothing a claim cannot
decode. Migration 0008 puts an agent check in front of it: every claim records its slot's agents in `slots`, and
`submit_task` refuses an agent no slot seen in the last day offers, naming the ones on offer, instead of queuing a task
nothing would claim. `submit` prints the task id; the idempotency key is `--key`, or else derived from the flags, so the same
submission again returns the same task. `exec-pool-migrate` is ordered after `postgresql-setup.service`, which
creates the role. From lenovo, the coordinator's host, `exec-pool` is a wrapper
(`sam.herdr.coordinatorWakeup.poolHost`, `modules/programs/cli/coordinator-wakeup.nix`) that runs acer's over ssh as
the same user, each argument single-quoted and the prompt on stdin (`--prompt-file -`), so the database stays
socket-only and lenovo holds no credential for it; skills `coordinator.poolCommand` names the wrapper.

## Sessions

`exec-pool start` (submit's flags, claude only) queues a session through `start_session` (migration 0009): a task
whose every lease is one turn. A turn ends in `Store::park`, one transaction fenced on its epoch, to `waiting` with
the try given back, so turns spend no `max_attempts` (a prepare failure still does); the park records the checkpoint
and the turn's result, marks the inbox rows the turn was handed read, and queues the next turn at once if an unread
row is due. `exec-pool send ID --prompt TEXT` puts a message in the session's inbox through `send_message`: a waiting
session is queued for it, one in `needs_review` is queued with its try given back (the owner's decision; besides an
operator's resolve the only way out of review), a queued or live one reads it at its next turn. There is no pause or
resume verb. A claim hands the turn the session's uuid, the prompt on its first turn or else the unread rows as one
text, and the highest row id it holds; rows are marked read at the park, so a turn that never ran is handed them
again. A **resume** is any wake (a message, a timer, a `continue` row): the next claim puts the session into a free slot's
pane on any host that reaches its tree, `--resume <uuid>`, so the pane shows the same conversation, with the unread
inbox as its input. `exec-pool attach ID` wakes a session with no message of the owner's (it is told the owner opened
it) and prints the host, slot and Herdr agent once its turn runs. What survives a pause: the transcript, the session
home and the work tree with uncommitted changes. What does not: running processes in the slot (dev servers,
background shells, a build in flight); a session's first turn is told so, to commit and push before it stops or waits and not rely on a background
process across a wait.
`exec-pool send ID --at HH:MM|RFC3339 --prompt TEXT` puts a timer row instead (`send_timer`, migration 0014),
due at that time (HH:MM the next one, local time); it changes no state, and `Store::reconcile`, which every runner runs
each loop, queues a waiting session once a row is due (one in `needs_review` stays there). In a slot,
`pool-wait --until HH:MM|RFC3339 [--note TEXT]` (no queue credential) writes one line
`{"due_at": "<RFC 3339 with offset>", "note": "<1 to 4096 bytes>" | null}` to `/session/cur/home/.pool-wait`, the
last call in a turn winning; the helper takes it from the dock once the turn's steps are gone (a regular file only, removed whatever it
held, one that does not parse dropped and noted), and the park puts it in through `wake_at` (the runner writes no
message), its note the turn's input and a `turn_end` parked as `waiting_until`. A message before the timer wakes the
session at once, and the timer row stays unread until it is due. `wait` returns on `waiting` too, `status` and `list` show `session` and, while waiting, the park reason, and
`exec_pool_waiting{reason}` counts waiting sessions by it.

Each park also writes a `turns` row (migration 0010): the tokens and cost Claude's result JSON reported, and
`handed_back`, whether the branch holds everything the checkout had (`TaskResult::handed_back`): after a turn its agent
reached, the helper lists `pool/<task id>` and runs `git status --porcelain=v2` in the checkout, true only when the
branch's commit is HEAD and nothing is uncommitted or untracked (`runner::holds_tree`). The textfile's
`exec_pool_session*` series count sessions by state and waiting reason, turns by park reason, turn and wake latency,
closed sessions' turns and age, parked sessions by idle age, host changes between turns and the reported tokens and
cost, each by host; the Agent harnesses dashboard's Sessions row draws them. There is nothing on a host to remove once a
session ends; its snapshot ref stays on the remote until a later park of it deletes it.
A park's own time (the agent's exit to the settle) is not
measured: no exit time reaches the queue. Wake latency starts when a row is due: when it was sent, or a timer's
`due_at`.

## How work is dispatched

The Coordinator hands out work only as pool sessions; there are no Herdr worker panes to hand to. On lenovo the
wake-up session's `coordinator-act` and `coordinator-read` reach the skills `pool:*` tasks, which call the `exec-pool`
wrapper above (`start`, `send`, `submit`, `wait`, `status`, `result`).

- An issue gets one session: `pool:start` under the key `coord:OWNER/REPO#N`, the issue text and rules as the first
  prompt. Its branch is `pool/<task id>`.
- Follow-up work on it (review findings, a merge conflict, "merge main and push") is `pool:send` to that same session,
  never a new one: the turn resumes the same transcript, branch and snapshot.
- `waiting` means the turn ended and the slot is free for other work; it needs nothing until there is a message to
  send. No session has to stay up for it.
- `needs_review` is the one state that wants a look: read `pool:result`, then `pool:send` the next step (that resumes
  it) or ask the owner on the issue.
- A review of an unreviewed PR head is a one-shot `pool:submit` at that head. A pool task cannot merge; a head graded
  9 or more is reported as ready to merge, and the interactive coordinator session merges it.

## Phase gates (detail in #646)

- **v0.1 local reuse:** one opt-in host, N declared slots (#650), a durable queue (#651), a runner (#652) and
  task-scoped isolation (#653): two safe tasks reuse one slot without a redeploy, a second concurrent claim is
  denied, named workers unaffected.
- **v0.2 fleet dispatch:** two hosts, capability-aware placement, fencing, drain and host loss (#654), native CLI
  adapter (#655); no automatic replay of an ambiguous mutation.
- **v0.3 portability:** checkpoint at a turn boundary, wake and resume on a compatible host or `needs_review` (#656),
  pinned upgrades and rollback (#657).

Each gate needs dated VM or live evidence (#658); a merge is not an activation.
