# Weekly goals: 23–29 November 2026

Outcome: a working metrics → alerts → investigation → fix → verification loop, and the specialist agent roles
that run it. Small PRs, shipped by nspawn workers, each merged batch deployed to the hosts it touches. Updated when
PRs merge.

## How we work (owner, 23 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break jumps the queue.
- No dedicated benchmarks. Ship behind a switch scoped to one host or worker and compare on the running system.
  Every feature that claims an improvement needs a switch, a metric that can tell on from off, and a regression alert.
- Deploy as we go; the execution pool's slots become the rollout unit.
- Night is reduced capacity, not a pause. msi and asus are off 21:00 to 08:30 and are never woken; acer (heavy work,
  one job at a time) and lenovo (edits only) keep working the queue with about two active workers. Only work that
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
Live: acer and msi at #750; lenovo behind (deploy in a quiet moment), asus and black-pi behind.

Live bugs, fixes in flight: `container@pool1` on acer hit its start limit after four short turns in ten minutes,
reset by hand (`m1`, `pool/slot-reset-clears-limit`); the session remover names dirs differently from the runner, so
it removes nothing and counts trees as orphans (`m2`, `pool/session-gc-names`).

Decided by the owner, 24 Nov: the pool is re-architected around sessions that park and wake by themselves, with no
pause or resume command. A task is a session, a lease is a turn, and every turn ends in a park to waiting. A wake is a
row in the session's inbox (`exec-pool send`, or a due timer). State lives outside the slot under the workers state
dir, is docked into a slot at `/session` for one turn, and is pushed to acer at every park so any host can continue
it. The named workers (a1, m1, m2; herman and t1 retired for pool2 by #748) become pool slots. Brief 656 (explicit pause and resume) is replaced by 1c.

Current batch: the two bug fixes above, #752 (store on acer) and timers, then one deploy of acer and msi; lenovo,
asus and black-pi follow.

Waiting, in pick-up order:

| # | Topic | Pain now | Next small change |
|---|-------|----------|-------------------|
| 1 | Sessions | a slot hits its start limit; the remover removes nothing | `m1` `pool/slot-reset-clears-limit` (replaces #751); `m2` `pool/session-gc-names` |
| 2 | Sessions | state is local to one slot | `a1` #752: push to the acer store at park, pull at claim |
| 3 | Sessions | msi powers off with sessions on it | drain before the msi 21:00 power-off, after #752 |
| 4 | Sessions | nothing wakes a parked session by itself | timers, `send --at` (`m2`) |
| 5 | Sessions | named workers sit outside the pool | a1, m1, m2 become slots, after the items above |
| 6 | Sessions | the coordinator dispatches through panes | dispatch through sessions (skills#162 gives `pool:start`, `send`, `wait`) |
| 7 | Sessions | no logs or priority per session | logs, priority |
| 8 | Sessions | a running turn cannot be displaced or watched | preemption and attach |
| 9 | Pool | any submitter reads every task's output | restrict to own tasks when a second submitter appears |
| 10 | Gates | first scheduled gate (15:20 to 15:57, 2256 s, main at #746) red on `shunt-metrics-test` only | fix rides with the start limit follow-up (`m1`); then read its per-step times |
| 11 | Live comparison | first numbers only | read a day of Shunt on/off on 25 Nov; the herman 300K side ends when its retirement deploys |
| 12 | Leftovers | one draft open | #616 (needs a physical reboot of black-pi) |

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
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | merged, skills#147; follow-up with `m2` |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | merged, skills#149 |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | closed 24 Nov: live named-role spawn and tests green |
| P2 | skills [#132](https://github.com/sammasak/skills/issues/132), [#134](https://github.com/sammasak/skills/issues/134), [#135](https://github.com/sammasak/skills/issues/135) | Remaining specialists | all merged: skills#153, #154, #155 |
| P1 | [#646](https://github.com/sammasak/nixos-config/issues/646) | Execution pool, v0.1 | split below; never ahead of a P0 item |
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

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | done: comment on #625 | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | merged, enabled on no host yet | #638 |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts, collector on lenovo | merged, live: collector on lenovo, rules on black-pi | #644 |
| 625-pilot | On/off on the running system (no benchmark, owner 23 Nov) | merged, live: on for lenovo and `a1`, off for herman; read a day on 25 Nov | #678, #679 |

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
| Sessions | Park and wake re-architecture (queue above); replaces brief 656 | #652 | live on acer and msi: first session parked, woke and resumed 24 Nov; store on acer (#752), timers and drain in flight | #744, #745, #746, #747, #748, #749, #750, #751 |
| v0.1 gate | Acceptance script in a VM: PASS, FAIL or UNTESTED per criterion | #653, #658 | | |

Per merged pool PR, record here: gate minutes, review rounds, hours from dispatch to merge.

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `a1` | #752 session store on acer, then drain before msi power-off |
| acer-swift | `pool1`, `pool2` | pool slots; `herman` retired, branches in `/var/lib/worker-archive` |
| msi-ms7758 | `m1` | slot reset clears the start limit, `shunt-metrics-test` fix |
| msi-ms7758 | `m2` | remover dir names, then timers |
| msi-ms7758 | `pool1`, `pool2` | pool slots; `t1` retired, branches in `/var/lib/worker-archive` |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

msi and asus have no `gh` login: workers push branches over SSH and the lenovo session opens and merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634. asus deployed again after #639 (workers retired).
msi, asus and acer deployed main again on the evening of 23 Nov (gaming entries, skills pin #661; acer also has the
pin from #670). lenovo and acer deployed #699 at 06:40 on 24 Nov, black-pi #694 at 05:00. On 24 Nov: asus #703 at 08:25, msi #714 at 10:00, acer #710 at 09:50 and #728 at 11:50 (the #725 deploy rolled back first: fixed by #728); acer and msi at #739, then #745 at 15:09 (sessions live), then #750 at 16:34 (acer) and 16:36 (msi). Lenovo's user slice (8.1G) hit its memory cap while two agents ran skills gates there: one at a time.

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
  pool2, #749 claim only where the state is, #750 session remover on, #751 no start limit on slot units
- skills: #141 role context (#138), #142 execution field (#130), #143 and #144 metrics analyst (#139),
  #145 incident investigator (#131), #146 improvement verifier (#140), #147 observability engineer (#137), #148 verifier follow-up,
  #149 nix platform engineer (#133), #151 and #152 handoffs pilot (#136), #153 nix exposure auditor (#132),
  #154 regression engineer (#134), #155 Rust maintainer (#135), #156 dangling pointer check,
  #157, #158 and #159 adapters name one place, #160 operator runbook line, #106 NUL in the bash hook, #162 coordinator `pool:start`, `pool:send`, `pool:wait`
