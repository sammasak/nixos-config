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

Current batch, then one acer deploy and the first real pool task: runner (#652, PR #713, `m2`), submit, status and list
commands (`m1`), pool metrics, dashboard row and two alerts (#658, `a1`).
Merged since 09:00: scheduled full gate and fast push checks (#707, #712); PostgreSQL in its own module (#708);
guest nix-daemon dies before agent sessions (#709, closes #647); annotation check reads black-pi's rule files (#710);
agent adapter (#711); msi guests resolve through the fleet's DNS host (#714); slot agents, `pool1` on acer (#716);
per-attempt workspace (#717). Live: acer up to #710, msi up to #714, black-pi #710.

Waiting, in pick-up order:

| # | Topic | Pain now | Next small change |
|---|-------|----------|-------------------|
| 1 | Pool | no task has run through it | deploy the batch on acer, submit one Claude task |
| 2 | Pool | the runner does not use the per-attempt workspace yet | wire `workspace` into the runner (#653) |
| 3 | Pool | one host only | fleet dispatch (#654); Codex and Pi need an egress route for slots |
| 4 | Gates | flake check took 1263 s after #683 | read the per-step times of the 15:20 scheduled gate |
| 5 | Live comparison | first numbers only | read a day of Shunt on/off and herman against default on 25 Nov |
| 6 | Leftovers | two drafts open; skills operator runbook names the old checkout | #616, skills#106, the runbook line |

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
| [#658](https://github.com/sammasak/nixos-config/issues/658) | Events to the journal, textfile metrics, dashboard row, two alerts | starts with #651 | first slice merged, live on acer: metrics, dashboard row, two alerts; canary and rollback evidence open | #719, #721 |
| [#652](https://github.com/sammasak/nixos-config/issues/652) | Runner: dispatcher, slot control, guest executor | #650, #651 | runner, agent adapter and submit/status/list CLI merged; first real task next | #711, #713, #720 |
| [#653](https://github.com/sammasak/nixos-config/issues/653) | Per-attempt isolation and egress | #652 | workspace merged; runner wiring next | #717 |
| v0.1 gate | Acceptance script in a VM: PASS, FAIL or UNTESTED per criterion | #653, #658 | | |

Per merged pool PR, record here: gate minutes, review rounds, hours from dispatch to merge.

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `a1` | #658 |
| acer-swift | `herman` | dashboards lane (#525, #523), not this week's list |
| msi-ms7758 | `m1` | pool submit command |
| msi-ms7758 | `m2` | #652 |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

msi and asus have no `gh` login: workers push branches over SSH and the lenovo session opens and merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634. asus deployed again after #639 (workers retired).
msi, asus and acer deployed main again on the evening of 23 Nov (gaming entries, skills pin #661; acer also has the
pin from #670). lenovo and acer deployed #699 at 06:40 on 24 Nov, black-pi #694 at 05:00. On 24 Nov: asus #703 at 08:25, msi #714 at 10:00, acer #710 at 09:50. Lenovo's user slice (8.1G) hit its memory cap while two agents ran skills gates there: one at a time.

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
  #710 annotation check on vendor rules, #711 agent adapter, #714 guest DNS, #716 slot agents, #717 attempt workspace
- skills: #141 role context (#138), #142 execution field (#130), #143 and #144 metrics analyst (#139),
  #145 incident investigator (#131), #146 improvement verifier (#140), #147 observability engineer (#137), #148 verifier follow-up,
  #149 nix platform engineer (#133), #151 and #152 handoffs pilot (#136), #153 nix exposure auditor (#132),
  #154 regression engineer (#134), #155 Rust maintainer (#135), #156 dangling pointer check,
  #157, #158 and #159 adapters name one place
