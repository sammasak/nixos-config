# ADR: Execution pool contract (v0.1, #649)

Status: proposed with #649's PR, for the owner to accept by merging. Epic: #646. This record freezes the data contract
and the owners; it adds no daemon, database, socket, port, Nix option or host change.

## Owners

| Concern | Owner | Where |
|---|---|---|
| Static slot capacity (how many reusable nspawn slots a host declares, their closure, cgroups, egress) | NixOS `services.devEnvironments`, changed only by a reviewed deploy | `modules/workers/core.nix`, `modules/workers/default.nix`, `modules/workers/execution-pool.nix` |
| Task and attempt state (queued to terminal, leases, epochs, idempotency keys) | the queue (#651, PostgreSQL) | `pkgs/exec-pool/src/queue.rs`, CLI `exec-pool-queue`; on acer (`modules/homelab/exec-pool.nix`) |
| Slot assignment on a host (claim, start, stop, sanitise, resource accounting) | a host-local runner (#652) | `pkgs/exec-pool/src/runner.rs`, `exec-pool-runner`; `modules/homelab/exec-pool-runner.nix`, on acer for `pool1` |
| The inner tool loop | the native Claude, Codex and Pi CLIs, unchanged | `docs/herdr.md` |
| Viewing sessions | Herdr, observe only: never the source of queue truth | `docs/herdr.md` |
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
`CheckpointRef` is an opaque versioned pointer (uri, digest) until #656 defines the manifest.

States (`pkgs/exec-pool/src/state.rs`, snake_case on the wire):

```text
queued -> leased -> running -> checkpointing -> waiting | queued | succeeded | failed | needs_review
waiting -> queued            (explicit wake)
leased  -> queued            (lease expired before its start was accepted)
running | checkpointing -> needs_review   (lease expired: effects unknown, never replayed blindly)
needs_review -> succeeded | failed | queued   (resolve: an operator's explicit decision, never automatic)
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
settle left, and only a settle to succeeded, failed or needs_review takes one (and must). Every lease but one that settles to
`waiting` (a planned pause) counts against `retry.max_attempts` (at least 1), so an expiring lease cannot loop. `TaskSpec`, `Attempt`, `Slot` and `Receipt` each
have a `parse()` that reads the version before any other field.

## Queue (#651)

PostgreSQL over a Unix socket only (`Store::open` refuses a TCP host), so the database's peer authentication is the
caller's. Schema `pkgs/exec-pool/migrations/0001_queue.up.sql`; forward-only in production, with
`exec-pool-queue migrate-down` dropping everything after the operator has exported what they keep. A claim locks only the queued
row it takes, `FOR UPDATE SKIP LOCKED`; every change runs `transition` and then the `attempts_fence` trigger, which refuses
a write that names any epoch but the current one (or none), moves the epoch by more than one, leases from anything
but queued, or touches a succeeded or failed attempt. One live attempt per slot is a unique index. A holder's event
after its lease deadline is refused; `reconcile` (at startup and on a timer) expires overdue leases. A database that
does not answer is `QueueError::Unavailable` (CLI exit 75), never an empty result, and a connection lost during COMMIT is
`QueueError::OutcomeUnknown` (exit 3): read the state (`Store::live_on` for a claim), never replay. The queue holds no GitHub or agent
token: the task's `credential_class` is resolved by the host. Prompt, argv and workdir stay in `tasks`; `events`
holds ids, states and reason codes.

Instrumentation (#658's first slice): every change is one JSON line on stdout, `{"msg":"state_change","change":{
task_id, attempt, lease_epoch, host, slot, from, to, reason, durations: {in_state_ms, since_submit_ms}}}`, and
`exec-pool-queue metrics` renders `exec_pool_queue_up`, `exec_pool_attempts{state,agent}`,
`exec_pool_queued_oldest_seconds`, `exec_pool_lease_overdue{state}`, `exec_pool_slots{state="busy"}`,
`exec_pool_slots_declared` (from `EXEC_POOL_SLOTS`), the histograms `exec_pool_queue_wait_seconds{agent}` and
`exec_pool_run_seconds{agent}` and `exec_pool_transitions_total{from,to,reason}` for a textfile collector; lease
expiries are the transitions with `reason="lease_expired"`. Ids stay in the log line, never in a label. When the render fails for any reason it prints only `exec_pool_queue_up 0`
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

## Runner (#652, first slice)

`exec-pool-runner-<slot>` (`modules/homelab/exec-pool-runner.nix`, `homelab.execPool.runner`, off by default; on acer
for its one slot `pool1`) runs as `exec_pool`, the queue's peer role, and loops: `reconcile`, `claim` for its slot
(agent `none`, the configured capabilities), `start`, then `systemctl start exec-pool-exec@<slot>`, then `checkpoint`
and `settle`, then `dev-env-reset@<slot>`. A polkit rule lets `exec_pool` start those two units of its own slots and
nothing else. The helper `exec-pool-exec@<slot>` runs as root and has no queue access. It reads the versioned manifest
(`runner::Manifest`: slot, attempt, epoch, task) from `/run/exec-pool-runner/<slot>/`, refusing a symlink. In the guest,
as its user and through `systemd-run -M`, it clones `source.repo` into `~/task`, checks out `source.rev` and runs
`agent::argv(&task)` in `command.workdir`. All three are argv, never a shell string, and the task is stopped at `timeoutSecs`.
Up to 1 MiB of each stream and the result go to `/var/lib/exec-pool-exec/<slot>/<hex attempt>-<epoch>/`, kept 30 days.

Settling (`runner::decide`): a clone or checkout that fails never started the task's argv, so the attempt goes back to
`queued`. A timeout, a guest that went away, or a missing result (or one for another attempt or epoch) goes to
`needs_review`. Otherwise `agent::outcome` decides from the exit code and the captured stdout. The command runs as a
oneshot unit, so only exit 0 is clean, and systemd-run's 255 (killed by a signal) counts as no exit code. A helper
that finds its attempt's run directory already there refuses to run it again. The receipt reports no effect. An event
the queue refuses, or one whose commit is unknown, is never re-sent: the lease (`timeoutSecs` + 1200 s) expires and
`reconcile` decides. Work never begins before `start` is accepted. The runner resets the slot at startup (its state
then is unknown) and after every run. A reset that fails three times writes `/var/lib/exec-pool-runner/<slot>.quarantined`,
and that slot is not claimed for again until an operator removes the marker and restarts the runner. Every state change
is one JSON line with its ids, and the `run` line carries exit code, output tails, `claim_to_exec_ms`, `exec_ms`,
`prepare_ms` and `run_ms`. `slot_reset` carries `sanitize_ms`. There are no metric labels.

## Not `sam.agentRuntime`

The historical `sam.agentRuntime` (#133, #138) made one ephemeral nspawn instance per task with no scheduler; it is
absent on main, its module directory was deleted in #210 (`git show 5a40362 --stat`). The current `modules/workers`
declares long-lived, named instances (`sam.workers.instances`, a `worker-herdr-<name>` unit per agent), each a Nix
deploy. The pool keeps those untouched and adds dynamic work on top of declared slots. `scripts/test-workers-eval.py`
pins it: `sam.workers.executionPool` (#650, `docs/nspawn-workers.md`, Execution pool) unset or off moves no
worker unit, container or toplevel on msi, and its instances (`m1`, `m2`, `t1`) and their Herdr units are pinned by name.

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
again. `wait` returns on `waiting` too, `status` and `list` show `session` and, while waiting, the park reason, and
`exec_pool_waiting{reason}` counts waiting sessions by it.

## Phase gates (detail in #646)

- **v0.1 local reuse:** one opt-in host, N declared slots (#650), a durable queue (#651), a runner (#652) and
  task-scoped isolation (#653): two safe tasks reuse one slot without a redeploy, a second concurrent claim is
  denied, named workers unaffected.
- **v0.2 fleet dispatch:** two hosts, capability-aware placement, fencing, drain and host loss (#654), native CLI
  adapter (#655); no automatic replay of an ambiguous mutation.
- **v0.3 portability:** checkpoint at a turn boundary, wake and resume on a compatible host or `needs_review` (#656),
  pinned upgrades and rollback (#657).

Each gate needs dated VM or live evidence (#658); a merge is not an activation.
