# Agent runtime: Herdr-visible identity and handoff (#139)

An ephemeral runtime's agent runs in a pane of the **physical host's Herdr
server** (the design decision on #139): one workspace per runtime, the pane's
command is the runtime launcher, and the PTY is the only channel. The container
has no Herdr socket, no network and no credential. Identity, title and state come
from the host-side adapter `agent-runtime-herdr`
(`modules/agent-runtime/herdr`, package `.#agent-runtime-herdr`), which speaks
only the stock `herdr 0.9.5` CLI.

| subcommand | what it does |
|---|---|
| `attach <id> <manifest.json> <OWNER/REPO#N> <status-file> -- <pane argv>` | workspace `rt-<id>`; `exec`s the launcher in the pane; once the foreground settles, `pane report-agent --agent agent-runtime --state unknown`, `agent rename rt-<id>`, `pane report-metadata --title "<OWNER/REPO#N> rt=<id> tpl=<digest12>"`; writes the registry record; starts `follow` |
| `attach <id> <manifest.json> <OWNER/REPO#N> <status-file> --mirror` | #169 status mirror: as above but the pane foreground is a benign placeholder that only waits (it starts **nothing**), the record gets `mirror: true` and the title `(mirror)`. For a run that is the direct root `agent-runtime-instance start` elsewhere; `<status-file>` is the root-written, world-readable `mirror.status` |
| `follow <id>` | maps the runtime's status file (in its own output mount) to `report-agent --state idle/working/blocked/unknown`; `finished` releases the agent, so Herdr stops listing it | For a `mirror: true` record it instead reads ONLY the root-written JSON `mirror.status` (`.state`: starting/running→working, succeeded→idle, failed/oom-killed/timed-out→blocked with the reason, else unknown), as the unprivileged Herdr user — never the instance tool, sudo or the credential.
| `deliver <id> <text>` | the handoff gate: only when both the registry and `herdr agent get` say idle (or done); otherwise exit 75 with the reason; types the text with `pane send-text` + Enter; logs its sha256 in the record | A `mirror: true` runtime is refused (exit 75) before any Herdr call — a mirror starts nothing.
| `detach <id>` | stops `follow`, releases the agent, closes the workspace, marks the record `torn_down` (works with Herdr down) |
| `status [--json]` | the registry, local only: answers when Herdr is unreachable |
| `reconcile` | after a Herdr restart: a record whose pane still runs the launcher `attach` saw is re-reported; any other is `lost`. Nothing is ever re-assigned |

The registry, `/var/lib/agent-runtime-herdr/<id>.json` (or
`$AGENT_RUNTIME_HERDR_STATE`), holds `runtime_id, host, herdr {workspace_id,
pane_id, name, foreground}, template, template_digest, harness, task_ref,
status, seq, deliveries, started_at, updated_at`. `status` is the runtime's
lifecycle (`started → idle ⇄ working | blocked → finished`, then `torn_down` or
`lost`); it is never a work verdict, which stays with the Coordinator's GitHub
evidence (`work_verdict`).

## What `herdr 0.9.5` does and does not allow (observed in the VM test)

- `pane report-agent` with a **known kind** (`claude`, `claude-code`) makes Herdr
  expect that program as the pane's foreground process; behind nspawn it never
  is, and `agent prompt` answers `agent rt-a1 is no longer the pane foreground
  process`. Hence the neutral label `agent-runtime`; the real harness stays in the
  registry.
- A reported agent is bound to the pane's foreground process at report time, so
  `attach` `exec`s the launcher (no shell left in front) and reports only once
  the foreground has settled.
- `agent prompt` only accepts a recognised agent kind (`agent w1:p1 is not an
  active named agent`), so the Coordinator's `herdr:message` cannot deliver to a
  runtime yet; `deliver` is the gate until Herdr prompts an agent it was told
  about. **Upstream requirement** (narrow): let `herdr agent prompt` (and
  `agent wait`) target a pane whose agent was reported with `pane report-agent`
  by a source that holds lifecycle authority, gated on that reported state, with
  the same bracketed-paste submission and `agent_blocked` refusal.
- The metadata title appears as the agent's `title` field (`agent list`,
  `agent get`); `terminal_title` stays the container's own. The Coordinator's
  inventory reads `terminal_title_stripped` today, so its `OWNER/REPO#N`
  correlation needs to read `title` too (skills #28).
- Stopping the Herdr server ends its panes' processes, the runtime's launcher
  included: a Herdr restart ends the runtime. Its output mount, results and
  registry survive; `reconcile` marks it `lost`, and `deliver` refuses a lost
  runtime, so nothing is assigned twice. Keeping the runtime alive across a
  Herdr restart needs the runtime to own its PTY (#138's lifecycle).

## Across machines (the coordinator host)

`packages.x86_64-linux.agent-runtime-herdr-machines-test` proves the
coordinator's view of another host's runtimes with two VMs: `rthost` runs the
runtimes under its own Herdr server (as acer-swift), `coord` (as lenovo) saves
it with `herdr machine add root@rthost --label rthost --remote-session default`
(what `sam.herdr.machines` runs at activation, `docs/herdr.md`) over SSH with a
pinned host key, and reads it with `herdr --machine rthost …`:

- **Discovery (#139 criterion 1).** `herdr --machine rthost agent list` lists
  `rt-a1` and `rt-b1` with `agent: agent-runtime` and the adapter's `title`
  (`<OWNER/REPO#N> rt=<id> tpl=<digest12>`), so the coordinator tells the
  runtimes apart by name, task and template digest without any access to
  rthost's registry. `terminal_title_stripped` is the container's own
  (`Container rt-a1 on rthost`); the coordinator's `herdr:inventory` reads that
  field today and has to read `title` for the correlation (skills #28).
- **The herdr:message route (criterion 2).** Its Herdr calls work across the
  machine up to the last one: `agent get` returns the runtime's reported state
  (`idle`/`done` passes the route's gate, `blocked` stops it with
  `agent_blocked`, a finished runtime is `agent_not_found`), and
  `agent prompt rt-a1 …` is refused with `agent_not_ready` ("not an active named
  agent"). Nothing reaches the runtime, nothing is recorded as delivered, so
  the route fails closed. Delivery to an idle runtime today is
  `agent-runtime-herdr deliver` on the runtime host; reaching it from the
  coordinator needs the upstream change below.
- **Reachability.** Herdr keeps its SSH connection to a saved machine: a host
  whose `sshd` stops but whose established session survives still answers.
  With the connection gone, `herdr --machine rthost agent list` fails
  (`remote SSH connection failed: … Connection refused`), so an unreachable
  host is an error to the inventory, never an empty fleet.

Runtime ids: the adapter accepts at most 29 characters (`rt-<id>` within
Herdr's 32). The lifecycle tool (`agent-runtime-instance`, #138, not on main
yet) is bounded the same in #155.

### Upstream requirement (draft for the owner to file with Herdr)

> **`agent prompt` / `agent wait` for agents reported with `pane report-agent`**
>
> herdr 0.9.5. An external supervisor registers a pane's agent with
> `herdr pane report-agent <pane> --source agent-runtime --agent agent-runtime --state idle --seq N`
> (and `agent rename <pane> rt-a1`, `pane report-metadata --title …`). Herdr
> then lists it (`agent list`, `agent get rt-a1` → `agent_status: idle`), also
> through `--machine`. But `herdr agent prompt rt-a1 'text'` fails with
> `agent_not_ready` ("agent rt-a1 is not an active named agent"), locally and
> via `--machine`. Reporting a built-in kind instead (`--agent claude`) is no
> way out: Herdr then expects that program as the pane's foreground process,
> which a program behind a container (nspawn) or a supervisor never is
> ("agent rt-a1 is no longer the pane foreground process").
>
> Request: let `agent prompt` (and `agent wait`, `prompt --wait`) target an
> agent whose state comes from `pane report-agent`, gated on that reported
> state: accept when it is `idle` or `done`, refuse with `agent_blocked` when
> `blocked` and `agent_not_ready` when `working`/`unknown`, submit exactly as
> for a built-in agent (bracketed paste plus Enter), and let `--wait` follow the
> reported state changes (`state_change_seq`). An explicit opt-in at report
> time (e.g. `pane report-agent … --promptable`) would keep today's behaviour
> for every other reporter. Built-in kind detection is unchanged; nothing new
> is needed for `--machine`, which already forwards these commands.
>
> Repro (the sequence the reporter runs, observed in its VM tests): `herdr workspace create
> --label rt-a1 --no-focus`; `herdr pane run <pane> 'exec <long-running program>'`; once the
> pane's foreground has settled, `herdr pane report-agent <pane> --source agent-runtime --agent
> agent-runtime --state unknown --seq 1`, `herdr agent rename <pane> rt-a1`, then
> `report-agent … --state idle --seq 2`; `herdr agent get rt-a1` (idle);
> `herdr agent prompt rt-a1 hello` (`agent_not_ready`).
