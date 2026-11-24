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

In flight (24 Nov, 01:10): next monitoring item (`a1`). Parked until msi is on (08:30): pool slot declaration (`m2`,
built and tested locally, unpushed); one full gate on main for the night's pushes (`just qa-owed`); msi and asus deploys.
Merged and live since 23:00: flake check evaluates each host once (#683); 300K compaction window on herman (#682);
Loki ruler with compactions per worker and an out-of-memory log alert (#684, #685); "On versus off" dashboard row
(#686); the repeat-failure alert clears 24 h after the last failure (#687); old PRs landed: typed textfile port
(#642), usage records (#637), asus model capability (#631).

Waiting, in pick-up order:

| # | Topic | Pain now | Next small change |
|---|-------|----------|-------------------|
| 1 | Workers | msi sessions die when the pool runs out of memory (#647) | cap or slot limit (needs msi on) |
| 2 | Pool | no task has run through it | push slots (#650), then the runner (#652); PostgreSQL and the pool enabled on acer |
| 3 | Roles | spawns so far ran without reading their contract (stale checkout, fixed) | one named-role spawn in a scratch checkout with the skills tests green (skills#136) |
| 4 | Gates | a full gate takes 20 to 60 minutes | read the morning gate against 13.1 min for the flake check; then the gate probe (3.6 min) |
| 5 | Live comparison | first numbers only | read a day of Shunt on/off and of herman against default; decide to widen or switch off |
| 6 | Monitoring | unknown whether backups record | read 24 Nov backup metrics; LogQL parse check for Loki rule queries; Alertmanager 0.34; next slice of #600 |
| 7 | Leftovers | two drafts open | #616 black-pi kernel (needs a build path that is not the Pi), skills#106 (fixes named on the PR) |

## Priorities

| P | Issue | Scope | State |
|---|-------|-------|-------|
| P0 | [#600](https://github.com/sammasak/nixos-config/issues/600) | Self-improvement milestone | all hosts on main of 23 Nov; live receipts to collect |
| P0 | [#624](https://github.com/sammasak/nixos-config/issues/624) | Actionable alerts | split below |
| P0 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt metrics, Grafana, alerts | split below |
| P1 | [skills#138](https://github.com/sammasak/skills/issues/138) | Thin global context, role context | merged, skills#141 |
| P1 | [skills#130](https://github.com/sammasak/skills/issues/130) | Write-capable role contracts | merged, skills#142 |
| P1 | [skills#139](https://github.com/sammasak/skills/issues/139) | Metrics analyst | merged, skills#143, #144 |
| P1 | [skills#131](https://github.com/sammasak/skills/issues/131) | Incident investigator | merged, skills#145 |
| P1 | [skills#140](https://github.com/sammasak/skills/issues/140) | Improvement verifier | merged, skills#146, #148 |
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | merged, skills#147; follow-up with `m2` |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | merged, skills#149 |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | offline pilot merged, skills#151; open for one live named-role spawn |
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
| 624-g | Live delivery receipts | queued: black-pi and lenovo are on main | |
| 624-h | alert-bridge renders query and runbook in the ntfy page (alert-bridge repo, then an app bump) | `m1`: bridge change and test update done, push gate running | |

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | done: comment on #625 | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | merged, enabled on no host yet | #638 |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts, collector on lenovo | merged, live: collector on lenovo, rules on black-pi | #644 |
| 625-pilot | Lenovo pilot, on/off benchmark | owner gate: token spend | |

### #646 execution pool (v0.1)

Nix declares slots; a separate runtime owns queue, leases and task state; workers, Herdr and the CLIs stay as they
are. v0.2 and v0.3 stay locked until the v0.1 offline gate has evidence. Deferred items: the checklist comment on #646.

| Item | What | Needs | State | PR |
|------|------|-------|-------|----|
| [#649](https://github.com/sammasak/nixos-config/issues/649) | Contract: ADR, `pkgs/exec-pool` types and state machine, compatibility fixture | | merged; acer gate 23 min, one review round plus a fix round, about 4 h from dispatch to merge | #667 |
| [#650](https://github.com/sammasak/nixos-config/issues/650) | `sam.workers.executionPool` slot count | #649 | `m2` | |
| [#651](https://github.com/sammasak/nixos-config/issues/651) | PostgreSQL queue, leases, fencing | #649 | `a1`, in gate | |
| [#658](https://github.com/sammasak/nixos-config/issues/658) | Events to the journal, textfile metrics, dashboard row, two alerts | starts with #651 | `a1`, first slice staged | |
| [#652](https://github.com/sammasak/nixos-config/issues/652) | Runner: dispatcher, slot control, guest executor | #650, #651 | queued | |
| [#653](https://github.com/sammasak/nixos-config/issues/653) | Per-attempt isolation and egress | #652 | queued | |
| v0.1 gate | Acceptance script in a VM: PASS, FAIL or UNTESTED per criterion | #653, #658 | | |

Per merged pool PR, record here: gate minutes, review rounds, hours from dispatch to merge.

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `a1` | #651, #658 |
| acer-swift | `herman` | dashboards lane (#525, #523), not this week's list |
| msi-ms7758 | `m1` | 624-h |
| msi-ms7758 | `m2` | #650 |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

msi and asus have no `gh` login: workers push branches over SSH and the lenovo session opens and merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634. asus deployed again after #639 (workers retired).
msi, asus and acer deployed main again on the evening of 23 Nov (gaming entries, skills pin #661; acer also has the
pin from #670). lenovo and black-pi deployed #687 at 01:05 on 24 Nov; acer follows when its worker is idle. Owed: msi and asus, after 08:30 on 24 Nov. Lenovo's user slice (8.1G) hit its memory cap while two agents ran skills gates there: one at a time.

## Gaming entries (owner request, 23 Nov)

asus: desktop, Steam, Sunshine streaming. msi: desktop and Steam, no Sunshine and no inbound ports. In the entry the
21:00 power-off does not run and inference is not started. Booted on neither host yet; the owner accepted it untested.
Steam Remote Play can still stream from msi through Valve's relay: the switch is in the Steam client.

## Owner gates

None, except physical access and spending money (owner, 23 Nov). The coordinator decides and ships everything else.
Owed after 08:30 on 24 Nov: one full gate on main (covers the night's pushes, `just qa-owed`), deploy msi and asus.

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
  alert clears, #642 typed textfile port, #637 usage records, #631 asus model capability
- skills: #141 role context (#138), #142 execution field (#130), #143 and #144 metrics analyst (#139),
  #145 incident investigator (#131), #146 improvement verifier (#140), #147 observability engineer (#137), #148 verifier follow-up,
  #149 nix platform engineer (#133), #151 and #152 handoffs pilot (#136), #153 nix exposure auditor (#132),
  #154 regression engineer (#134), #155 Rust maintainer (#135)
