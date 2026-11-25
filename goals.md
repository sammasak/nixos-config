# Weekly goals: 23–29 November 2026

Outcome: a working metrics → alerts → investigation → fix → verification loop, and the specialist agent roles
that run it. Small PRs, shipped by execution pool sessions, each merged batch deployed to the hosts it touches. Updated when
PRs merge. The direction this queue serves: [vision.md](vision.md).

## How we work (owner, 23 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break jumps the queue.
- No dedicated benchmarks. Ship behind a switch scoped to one host or worker and compare on the running system.
  Every feature that claims an improvement needs a switch, a metric that can tell on from off, and a regression alert.
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send` for each follow-up), never to Herdr
  panes. Deploy as we go; the execution pool's slots are the rollout unit.
- Night is reduced capacity, not a pause. msi and asus are off 21:00 to 08:30 and are never woken; acer (heavy work,
  one job at a time) and lenovo (edits only) keep working the queue with about two active sessions. Only work that
  needs msi or asus waits for the morning.
- Prefer upstream nixpkgs modules and built-in features over home-made services.

## Queue

Owner, 24 Nov: ship the real work with a narrow test per change; no long gate per change. Merges and deploys are
collected into a batch, and the scheduled full gate on main (acer, four times a day, first run 15:20) covers the batch.

First real task ran through the pool on 24 Nov at 11:53: a Claude task submitted with `exec-pool submit` on acer,
claimed by `pool1`, cloned, run and settled as succeeded in 12 s, slot reset.
Merged since 10:00: pool metrics, dashboard row and two alerts (#719, #721); submit, status and list (#720); runner
runs slot agents in the attempt workspace (#725); fleet dispatch listener and credential, off by default (#726, #730);
Codex and Pi in slots (#727); systemd-run no longer expands task text (#728); result and wait (#729);
`typed-interfaces-test` green again (#731); fleet credential fix (#733); heartbeats, cancel and record_result with a
300 s lease (#734, #735); msi slot and runner, so the pool runs on acer and msi (#736); a task pushes its own branch
`pool/<task id>` and reports it (#737); `exec-pool submit` from lenovo plus skills pin (#738); submit refuses an agent
no live slot offers, and acer offers pi (#739); rollback across a migration and visible slot quarantine (#740).
Since 14:25: sessions are live (#744 queue with inbox, park and send; #745 turn in a slot; deployed 15:09). The
first live session, `cli-c86629271199d5b7` on acer, parked itself after 14 s, `exec-pool send` woke it 6 s later,
and it resumed with its transcript and an uncommitted file intact. Then session housekeeping (#746: gcroots, disk
metric, remover), session metrics with tokens and cost per turn, `exec-pool sessions --gc` and a dashboard row
(#747), t1 and herman retired for a second pool slot on msi and acer, their unpushed branches bundled to
`/var/lib/worker-archive` on each host (#748), a session claimed only on a host that holds its state (#749), the
remover on, for sessions handed back whole only, final after 7 days or waiting idle 14 days (#750), and no start
limit on slot units (#751, being replaced: the slot reset clears the limit instead). skills#162: coordinator
`pool:start`, `pool:send`, `pool:wait`.
Since 16:40 (live on acer and msi at #764 unless noted): slot reset clears the start limit (#755), remover dir names
(#756), GitHub sidecar for acer slots (#757), drain before power-off with a drained one-shot going to review (#758),
a1, m1 and m2 retired for three slots on acer and four on msi, unpushed work bundled under `/var/lib/worker-archive`
(#759), the coordinator dispatches only as pool sessions (#760, #761; skills#163, #164), timers and `handed_back`
(#762, #763), msi slots reach GitHub through acer's sidecar with no key on any slot and private clones through the
proxy (#764), a timed-out turn continues up to three times (#765, merged, not deployed).
Live proofs: a timer woke a parked session at 17:59:02; a session ran turn 1 on acer and turn 2 on msi with its
state, and pushed from msi through acer's sidecar to the private skills repo; state is pushed to the acer store at
every park.

Live findings, 19:00: acer `pool1` sat quarantined 15:11 to 17:27 with no alert (only `ExecPoolQueueDown` is loaded
in Prometheus); a failed prepare leaves an empty result; slot metrics exist for acer only; the first msi deploy at
18:06 rolled back on a slot reset overlapping activation (the retry passed); lenovo cannot push nixos-config (its
devenv gate is stale and re-entering builds) nor fetch a new private skills pin as a user.

Decided by the owner, 24 Nov: the pool is re-architected around sessions that park and wake by themselves, with no
pause or resume command. A task is a session, a lease is a turn, and every turn ends in a park to waiting. A wake is a
row in the session's inbox (`exec-pool send`, or a due timer). State lives outside the slot under the workers state
dir, is docked into a slot at `/session` for one turn, and is pushed to acer at every park so any host can continue
it. The named workers are pool slots now: herman and t1 retired for pool2 by #748; a1, m1 and m2 retired for acer's
pool3 and msi's pool3 and pool4 by #759. Brief 656 (explicit pause and resume) is replaced by 1c.

Current batch, 20:32: pool metrics and alerts (#768), turn timeout (#765, #770), Shunt alerts (#771), priority and
logs (#772) and deploy drain (#773) are merged and deployed; lenovo deployed #774 at 20:32. Only asus is behind.

State at 25 Nov 02:30: interactive panes for pool sessions are live on acer (#780); msi follows after 08:30. Git-backed
session state is in flight (branch `pool/cli-fd59cf28cf1b122c`). Night: a cheaper agent drives the live checks and
merges from a runbook; the coordinator wakes on finish events and after two quiet hours.

### Pool platform: how we iterate

Owner, 24 Nov 20:40: "ensure that we iterate on this platform so that we can improve this". The list lives on
[#646](https://github.com/sammasak/nixos-config/issues/646) and here.

How we iterate: every coordinator check-in reads the live signals below, adds what it finds to this list, and starts a
pool session for the top open finding. A finding is closed by a merged PR that is deployed and seen in the signal, not
by a test.

**Signals (Prometheus, all by `host`)**: `exec_pool_slots{state}` (busy, idle, quarantined),
`exec_pool_transitions_total{reason}` (turn_timeout, turn_error, host_draining, needs_review), queue wait and wake
latency histograms, `exec_pool_session_turn_seconds`, turns per session, `exec_pool_session_cost_usd_total` and tokens,
store transfers, `shipping_deploy_lag_hours`. Alerts: the nine `ExecPool*` rules, `HostBehindMain`, `DeployRolledBack`.

**Found live on 24 Nov and fixed**: silent quarantine with no alert loaded (#768 plus the black-pi deploy), slot
metrics for acer only (#768), a turn cut at 30 minutes left its session waiting for ever (#765), a slot reset racing a
deploy's activation (#768), stale Shunt alerts for retired workers (#771), deploys waiting for an idle pool and a turn
lost when the queue restarts (#773), no claim priority (#772).

**Found live on 24/25 Nov, fixed in branch `pool/cli-bae083cc3a959222`** (deploy acer and msi): a turn that ends in an
error now gets up to three continues, due 10, 30 and 90 minutes later, each a new turn told what happened; a session
left with nothing to wake it after errors or timeouts is counted in `exec_pool_sessions_stalled{reason}` and alerts
(ExecPoolSessionStalled). `gh pr create` and `gh pr comment` failed because they use GraphQL, which the proxy refuses:
pool tasks are told the REST calls (`gh api repos/<repo>/pulls`, `.../issues/N/comments`) the proxy already passes.
The proxy fetches any other repository unsigned and read-only (truespar/scriptor). The old layout's session trees and
`.sessions-store` are removed daily when cancelled or handed back on their branch, the rest counted
(`homelab_exec_pool_legacy_sessions_kept{reason}`).

**Found live on 24/25 Nov, fixed in branch `pool/cli-3298c29ab4554a39`** (deploy acer and msi): an interactive
turn waiting on its own background command (a build started in the background) looked idle and parked after the grace,
which killed the command; a live Bash tool command of the agent in its slot's turn unit now keeps it busy, the 30 minute
limit still the outer bound. `just pool-merge-check` built exec-pool alone; it now builds each `pkgs/<dir>` the branch
changes (`pkgsDir.<dir>`) and names them, nothing when none changed, so a lint failing inside a package build (ruff
E501 last night) is caught before merge. A background subagent (no process of its own) still looks idle.

**Open, in pick-up order**

1. Session turns are headless; the owner wants the same interactive Herdr panes the named workers had, with an idle
   grace period, park, resume into a pane and `attach`: live on acer (#780), msi after 08:30.
2. Two PRs that each built alone broke main together (#765 with #768). Build the merge result of a pool crate PR
   before merging it: `just pool-merge-check BRANCH` on acer, before each merge that touches `pkgs/`.
3. Three sessions lost a turn to the 30 minute limit today. Re-check the limit once turns are interactive and park on
   idle.
4. Not yet seen live: a drain started by `just deploy`, claim order by priority, the prepare failure counter,
   `coord:brief` against the real CLI.
5. The drain starts before the build, so a long build keeps a host from claiming.
6. Slots run without a user namespace and `lukas` is in `wheel` in the guest.
7. `status` and `list` do not show priority.
8. `HostBehindMain` needs 24 h; black-pi lacked new alert rules for some hours unseen.
9. lenovo cannot push nixos-config (stale devenv gate) or fetch a new private skills pin as a user.
10. Cost: about 45 USD of session cost on 24 Nov; track cost per merged PR.
11. Store follow-ups in #754; credential slices 3 and 4.
12. Session state lives in git (#781, merged); its old trees and store are removed by the legacy remover once deployed.
13. The proxy cannot hold a pull request to the task's own repository and `pool/<task id>` branch: the head is in the
    request body, which Caddy does not read, and acer's fleet site does not know which slot asks. Today any listed
    repository, any head; a body-reading gate would close it.
14. A turn whose input never reached the agent is queued again at once, skipping the error backoff, and never counts as
    stalled (pre-existing; the runner cannot move a message's `due_at`).

### Paddock SSD-backed MoE expert streaming

Same priority as the pool platform. One dedicated pool session drives it end to end from draft
[paddock#2](https://github.com/sammasak/paddock/pull/2) (packaging: paddock#1; integration: #508; feasibility and
benchmark requirements: #776; epic: #491).

- Paddock before Strata.
- Isolated behind a narrow abstraction, the existing fast path kept, fork maintenance kept small.
- Decisions, progress, acceptance criteria and follow-ups live in those issues and PRs.
- Small reviewed changes with measured results on asus (asus is off 21:00 to 08:30).
- 25 Nov 02:30: steps 1 to 4 done on the CPU side in draft [paddock#3](https://github.com/sammasak/paddock/pull/3);
  the first asus runs follow after 08:30, per the run list on #508.
- Aim: a polished upstream contribution.

### Waiting, in pick-up order

| # | Topic | Pain now | Next small change |
|---|-------|----------|-------------------|
| 1 | Pool platform | the open findings above | a pool session for the top open finding |
| 2 | Deploy | asus behind main | asus in its power window |
| 3 | Alerts | 624-i fixes the alerts nobody could act on; not yet read live (pool slots reach neither Prometheus nor Alertmanager) | merge and deploy 624-i, then read the live list; a1's patch at `/var/lib/worker-archive/a1` on acer |
| 4 | Gates | scheduled gate red since 24 Nov on `checks.x86_64-linux.execution-pool-vm`, which failed to evaluate (slots' repos need `sam.workers.ghHostsFile`, the VM set none); fixed in branch `pool/cli-38a64f8b5b1d81f5` | merge, deploy acer (scheduled gate) and black-pi (rules), read the next scheduled gate result |
| 5 | Live comparison | `ShuntCollectorStale` fires since the on side moved | read a day of Shunt on and off on 25 Nov, now on acer `pool1` |
| 6 | Leftovers | one draft open | #616 (needs a physical reboot of black-pi) |

## Priorities

| P | Issue | Scope | State |
|---|-------|-------|-------|
| P0 | [#600](https://github.com/sammasak/nixos-config/issues/600) | Self-improvement milestone | all hosts on main of 23 Nov; first live receipts on #624 and #625 (24 Nov) |
| P0 | [#624](https://github.com/sammasak/nixos-config/issues/624) | Actionable alerts | split below |
| P0 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt metrics, Grafana, alerts | split below |
| P1 | [skills#138](https://github.com/sammasak/skills/issues/138) | Thin global context, role context | merged, skills#141 |
| P1 | [skills#130](https://github.com/sammasak/skills/issues/130) | Write-capable role contracts | merged, skills#142 |
| P1 | [skills#139](https://github.com/sammasak/skills/issues/139) | Metrics analyst | merged, skills#143, #144 |
| P1 | [skills#131](https://github.com/sammasak/skills/issues/131) | Incident investigator | merged, skills#145 |
| P1 | [skills#140](https://github.com/sammasak/skills/issues/140) | Improvement verifier | merged, skills#146, #148 |
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | merged, skills#147; follow-up waits for a pool session (m2 retired) |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | merged, skills#149 |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | closed 24 Nov: live named-role spawn and tests green |
| P2 | skills [#132](https://github.com/sammasak/skills/issues/132), [#134](https://github.com/sammasak/skills/issues/134), [#135](https://github.com/sammasak/skills/issues/135) | Remaining specialists | all merged: skills#153, #154, #155 |
| P1 | [#646](https://github.com/sammasak/nixos-config/issues/646) | Execution pool, v0.1 | split below; never ahead of a P0 item |
| P1 | [paddock#2](https://github.com/sammasak/paddock/pull/2) | Paddock SSD-backed MoE expert streaming | one dedicated pool session; see the queue above |
| P2 | [#626](https://github.com/sammasak/nixos-config/issues/626) | Auto-compaction benchmarks | matrix doc when idle; benchmark is token spend |

## Work items

### #624 actionable alerts

| Item | What | State | PR |
|------|------|-------|----|
| 624-a | Inventory: signal → rule → route → last receipt → gap | merged | #629 |
| 624-b | Annotation contract (summary, description, query, runbook), asserted by a check | merged, deployed | #632, #636 |
| 624-c | OTLP relay rejection alert (the monitoring-blindness example) | merged, live on black-pi; no rejected write seen live yet | #659 |
| 624-d | Journal-delivery stale alert | merged, live on black-pi | #640 |
| 624-e | Backup stale, never recorded, collector stale | merged, live on black-pi; first recorded runs due 24 Nov 03:00 | #640 |
| 624-f | Synthetic fire and resolve test through Alertmanager and alert-bridge | merged | #666 |
| 624-g | Live delivery receipts | read 24 Nov (comment on #624): NodeOOMKill and the synthetic alert reached ntfy and resolved; no blindness alert has fired yet | |
| 624-h | Query and runbook in the ntfy page | merged, live: Alertmanager posts straight to ntfy, alert-bridge removed | #672, #680 |
| 624-i | Alerts red with nothing to do (25 Nov): DeployRolledBack per host until a good deploy of it; EscapeFound drops a reapplied revert (the live one, `78f4ee80`, reapplied as `ab8acd36`), one marked `Escape: no` and closed escape issues; the scheduled gate retries a red head once; RetroDueStepFailsRepeat clears on a scheduled green after the last failure; each text names its command | branch `pool/cli-273036d46c7d3230`; needs lenovo (collector) and acer (scheduled gate), rules on black-pi | |

Open for #624, in pick-up order: after 624-i deploys, read the live list and confirm each alert cleared or names
its command; the failing check behind the live ScheduledGateRed and RetroDueStepFailsRepeat was `checks.x86_64-linux.execution-pool-vm` failing to evaluate, which wrote no check record (branch `pool/cli-38a64f8b5b1d81f5`: the VM fixed, an eval failure now records its check, the red series carries `check`, and both alerts name one rerun command, `nix build -L .#<check>` or `NIXOS_STEP=<step> devenv tasks run nixos:step`); an intentional revert that is never reapplied still counts for 24 h (no after-the-fact
acknowledgement); `query` on TargetDown and the llm-gateway rules.

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | done: comment on #625 | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | merged, enabled on no host yet | #638 |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts, collector on lenovo | merged, live: collector on lenovo, rules on black-pi | #644 |
| 625-pilot | On/off on the running system (no benchmark, owner 23 Nov) | merged, live: on for lenovo and acer's `pool1` (moved from `a1` by #759), off for acer's other slots; read a day on 25 Nov | #678, #679 |
| 625-3 | Hook overhead: `shunt_hook_time_ms{hook}` with validate-bash as the off side's control, ms per Bash call on and off (dashboard panel), `ShuntHookOverhead` (over 250 ms per call, at least 50 calls, a starting bound) | branch `pool/cli-273036d46c7d3230`; needs lenovo and acer, rules on black-pi; set the bound from the first day's reading | |

### #646 execution pool (v0.1)

Nix declares slots; a separate runtime owns queue, leases and task state; workers, Herdr and the CLIs stay as they
are. v0.2 and v0.3 stay locked until the v0.1 offline gate has evidence. Deferred items: the checklist comment on #646.

| Item | What | Needs | State | PR |
|------|------|-------|-------|----|
| [#649](https://github.com/sammasak/nixos-config/issues/649) | Contract: ADR, `pkgs/exec-pool` types and state machine, compatibility fixture | | merged; acer gate 23 min, one review round plus a fix round, about 4 h from dispatch to merge | #667 |
| [#650](https://github.com/sammasak/nixos-config/issues/650) | `sam.workers.executionPool` slot count | #649 | closed; `pool1` declared on acer | #704, #716 |
| [#651](https://github.com/sammasak/nixos-config/issues/651) | PostgreSQL queue, leases, fencing | #649 | closed; live on acer | #673, #693 |
| [#658](https://github.com/sammasak/nixos-config/issues/658) | Events to the journal, textfile metrics, dashboard row, two alerts | starts with #651 | first slice merged, live on acer: metrics, dashboard row, two alerts | #719, #721 |
| [#652](https://github.com/sammasak/nixos-config/issues/652) | Runner: dispatcher, slot control, guest executor | #650, #651 | live on acer: first Claude task succeeded 24 Nov; heartbeats, cancel, record_result, own branch per task and submit refusal merged | #711, #713, #720, #725, #728, #729, #734, #735, #737, #738, #739, #740 |
| [#653](https://github.com/sammasak/nixos-config/issues/653) | Per-attempt isolation and egress | #652 | merged, live: each attempt runs in its own workspace; Codex and Pi routes in slots | #717, #725, #727 |
| [#654](https://github.com/sammasak/nixos-config/issues/654) | Fleet dispatch: msi runner against acer's queue | #652 | merged, live: the pool runs on acer and msi | #726, #730, #733, #736 |
| Sessions | Park and wake re-architecture (queue above); replaces brief 656 | #652 | live on acer and msi: first session parked, woke and resumed 24 Nov; store on acer, drain, timers, sidecar and pool-only coordinator live at #764; #765 merged | #744 to #752, #755 to #765 |
| v0.1 gate | Acceptance script in a VM: PASS, FAIL or UNTESTED per criterion | #653, #658 | | |

Per merged pool PR, record here: gate minutes, review rounds, hours from dispatch to merge.

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `pool1` to `pool3` | pool slots, Shunt on for `pool1`; `herman` and `a1` retired, their work in `/var/lib/worker-archive` |
| msi-ms7758 | `pool1` to `pool4` | pool slots; `t1`, `m1` and `m2` retired, their work in `/var/lib/worker-archive` |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

No slot holds a GitHub key: acer's and msi's slots push through acer's GitHub sidecar, private clones go through the
proxy, and the owner merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634. asus deployed again after #639 (workers retired).
msi, asus and acer deployed main again on the evening of 23 Nov (gaming entries, skills pin #661; acer also has the
pin from #670). lenovo and acer deployed #699 at 06:40 on 24 Nov, black-pi #694 at 05:00. On 24 Nov: asus #703 at 08:25, msi #714 at 10:00, acer #710 at 09:50 and #728 at 11:50 (the #725 deploy rolled back first: fixed by #728); acer and msi at #739, then #745 at 15:09 (sessions live), then #750 at 16:34 (acer) and 16:36 (msi), then #764 (the first msi deploy at 18:06 rolled back on a slot reset overlapping activation; the retry passed). Lenovo's user slice (8.1G) hit its memory cap while two agents ran skills gates there: one at a time.

## Gaming entries (owner request, 23 Nov)

asus: desktop, Steam, Sunshine streaming. msi: desktop and Steam, no Sunshine and no inbound ports. In the entry the
21:00 power-off does not run and inference is not started. Booted on neither host yet; the owner accepted it untested.
Steam Remote Play can still stream from msi through Valve's relay: the switch is in the Steam client.

## Owner gates

None, except physical access and spending money (owner, 23 Nov). The coordinator decides and ships everything else.
The scheduled gate on acer runs the full gate on main; nothing is owed by hand.

## Merged this week

- nixos-config: #629 alert inventory, #630 asus workers, #632 and #636 annotation contract, #633 acer and msi slots,
  #634 journal-metrics wants alloy, #635 Claude sessions keep a working shell across a deploy, #638 Shunt collector, #639 asus workers retired,
  #640 backup and journal alerts, #643 and #661 skills pins, #644 Shunt dashboard and alerts, #659 OTLP rejection alert,
  #662 and #665 asus gaming entry with Sunshine, #668 msi gaming entry without streaming,
  #669 Steam in both entries and no scheduled power-off while gaming, #666 synthetic fire and resolve test,
  #667 execution pool contract, #670 skills pin, #671 priority queue, #672 runbook link and query in the
  notification, #673 pool queue, #675 pool CLI and metrics, #676 night mode, #678 and #679 Shunt on for a1 with
  on/off labels, #680 Alertmanager posts to ntfy and alert-bridge removed, #682 compaction window per worker,
  #683 one eval per host in the flake check, #684 and #685 Loki ruler, #686 on versus off row, #687 repeat-failure
  alert clears, #642 typed textfile port, #637 usage records, #631 asus model capability, #689 late-failure guard,
  #690 seventh-host reuses evaluations, #691 role adapters pinned to the skills input, #693 pool queue on acer,
  #694 and #695 flake check green again, #697 guest records shipped by the host only, #698 night eval step,
  #699 skills pin, #701 untouched issues alert, #702 compaction loop alert, #703 skills pin, #704 pool slots,
  #705 record backlog alert, #707 and #712 scheduled gate, #708 PostgreSQL module, #709 guest daemon OOM order,
  #710 annotation check on vendor rules, #711 agent adapter, #714 guest DNS, #716 slot agents, #717 attempt workspace,
  #719 and #721 pool metrics and alerts, #720 submit CLI, #722 inventory with one slot, #724 skills pin,
  #725 runner in the attempt workspace, #726 and #730 fleet dispatch listener and credential, #727 Codex and Pi in slots,
  #728 no expansion of task text, #729 result and wait, #731 typed interfaces green,
  #733 fleet credential fix, #734 heartbeats, cancel and record_result, #735 exec-pool cancel, #736 msi slot and runner,
  #737 task pushes its own branch, #738 submit from lenovo and skills pin, #739 submit refuses an agent no slot offers,
  #740 rollback across a migration and slot quarantine, #744 session queue, inbox, park and send, #745 session turn
  in a slot, #746 session housekeeping, #747 session metrics and `sessions --gc`, #748 t1 and herman retired for
  pool2, #749 claim only where the state is, #750 session remover on, #751 no start limit on slot units, #752 session state in the acer store,
  #755 slot reset clears the start limit, #756 remover dir names, #757 GitHub sidecar for acer slots, #758 drain before
  power-off, #759 a1, m1 and m2 retired for slots, #760 and #761 coordinator dispatches as pool sessions, #762 and #763
  timers and `handed_back`, #764 msi slots through acer's sidecar, #765 a timed-out turn continues
- skills: #141 role context (#138), #142 execution field (#130), #143 and #144 metrics analyst (#139),
  #145 incident investigator (#131), #146 improvement verifier (#140), #147 observability engineer (#137), #148 verifier follow-up,
  #149 nix platform engineer (#133), #151 and #152 handoffs pilot (#136), #153 nix exposure auditor (#132),
  #154 regression engineer (#134), #155 Rust maintainer (#135), #156 dangling pointer check,
  #157, #158 and #159 adapters name one place, #160 operator runbook line, #106 NUL in the bash hook, #162 coordinator `pool:start`, `pool:send`, `pool:wait`,
  #163 and #164 pool-aware idle check, sessions in `work:status` and `coord:brief`
