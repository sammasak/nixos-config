# ADR: Execution pool contract (v0.1, #649)

Status: proposed with #649's PR, for the owner to accept by merging. Epic: #646. This record freezes the data contract
and the owners; it adds no daemon, database, socket, port, Nix option or host change.

## Owners

| Concern | Owner | Where |
|---|---|---|
| Static slot capacity (how many reusable nspawn slots a host declares, their closure, cgroups, egress) | NixOS `services.devEnvironments`, changed only by a reviewed deploy | `modules/workers/core.nix`, `modules/workers/default.nix`, `modules/workers/execution-pool.nix` |
| Task and attempt state (queued to terminal, leases, epochs, idempotency keys) | the queue (#651, PostgreSQL) | `pkgs/exec-pool/src/queue.rs`, CLI `exec-pool-queue`; on acer (`modules/homelab/exec-pool.nix`), nothing claims yet |
| Slot assignment on a host (claim, start, stop, sanitise, resource accounting) | a host-local dispatcher (#652) | not built |
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

## Not `sam.agentRuntime`

The historical `sam.agentRuntime` (#133, #138) made one ephemeral nspawn instance per task with no scheduler; it is
absent on main, its module directory was deleted in #210 (`git show 5a40362 --stat`). The current `modules/workers`
declares long-lived, named instances (`sam.workers.instances`, a `worker-herdr-<name>` unit per agent), each a Nix
deploy. The pool keeps those untouched and adds dynamic work on top of declared slots. `scripts/test-workers-eval.py`
pins it: `sam.workers.executionPool` (#650, `docs/nspawn-workers.md`, Execution pool) unset or off moves no
worker unit, container or toplevel on msi, and its instances (`m1`, `m2`, `t1`) and their Herdr units are pinned by name.

## Phase gates (detail in #646)

- **v0.1 local reuse:** one opt-in host, N declared slots (#650), a durable queue (#651), a runner (#652) and
  task-scoped isolation (#653): two safe tasks reuse one slot without a redeploy, a second concurrent claim is
  denied, named workers unaffected.
- **v0.2 fleet dispatch:** two hosts, capability-aware placement, fencing, drain and host loss (#654), native CLI
  adapter (#655); no automatic replay of an ambiguous mutation.
- **v0.3 portability:** checkpoint at a turn boundary, wake and resume on a compatible host or `needs_review` (#656),
  pinned upgrades and rollback (#657).

Each gate needs dated VM or live evidence (#658); a merge is not an activation.
