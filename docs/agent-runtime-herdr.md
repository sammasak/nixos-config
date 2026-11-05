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
| `follow <id>` | maps the runtime's status file (in its own output mount) to `report-agent --state idle/working/blocked/unknown`; `finished` releases the agent, so Herdr stops listing it |
| `deliver <id> <text>` | the handoff gate: only when both the registry and `herdr agent get` say idle (or done); otherwise exit 75 with the reason; types the text with `pane send-text` + Enter; logs its sha256 in the record |
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
