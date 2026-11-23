# Weekly goals: 23–29 November 2026

Outcome: a working metrics → alerts → investigation → fix → verification loop, and the specialist agent roles
that run it. Small PRs, shipped by nspawn workers, each merged batch deployed to the hosts it touches. Updated when
PRs merge.

## Priorities

| P | Issue | Scope | State |
|---|-------|-------|-------|
| P0 | [#600](https://github.com/sammasak/nixos-config/issues/600) | Self-improvement milestone | all hosts on main of 23 Nov; live receipts to collect |
| P0 | [#624](https://github.com/sammasak/nixos-config/issues/624) | Actionable alerts | split below |
| P0 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt metrics, Grafana, alerts | split below |
| P1 | [skills#138](https://github.com/sammasak/skills/issues/138) | Thin global context, role context | merged, skills#141 |
| P1 | [skills#130](https://github.com/sammasak/skills/issues/130) | Write-capable role contracts | merged, skills#142 |
| P1 | [skills#139](https://github.com/sammasak/skills/issues/139) | Metrics analyst | merged, skills#143; follow-up in review |
| P1 | [skills#131](https://github.com/sammasak/skills/issues/131) | Incident investigator | in review |
| P1 | [skills#140](https://github.com/sammasak/skills/issues/140) | Improvement verifier | `m2` |
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | queued |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | queued |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | last: needs #139 plus #131 or #137 |
| P2 | skills [#132](https://github.com/sammasak/skills/issues/132), [#134](https://github.com/sammasak/skills/issues/134), [#135](https://github.com/sammasak/skills/issues/135) | Remaining specialists | when idle |
| P2 | [#626](https://github.com/sammasak/nixos-config/issues/626) | Auto-compaction benchmarks | matrix doc when idle; benchmark is token spend |

## Work items

### #624 actionable alerts

| Item | What | State | PR |
|------|------|-------|----|
| 624-a | Inventory: signal → rule → route → last receipt → gap | merged | #629 |
| 624-b | Annotation contract (summary, description, query, runbook), asserted by a check | merged, deployed | #632, #636 |
| 624-c | OTLP relay rejection alert (the monitoring-blindness example) | queued | |
| 624-d | Journal-delivery stale alert | `m1` | |
| 624-e | Backup-completion stale alert | `m1` | |
| 624-f | Synthetic fire and resolve test through Alertmanager and alert-bridge | queued | |
| 624-g | Live delivery receipts | queued: black-pi and lenovo are on main | |
| 624-h | alert-bridge renders query and runbook in the ntfy page (alert-bridge repo, then an app bump) | queued | |

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | done: comment on #625 | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | `a1` | |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts | queued | |
| 625-pilot | Lenovo pilot, on/off benchmark | owner gate: token spend | |

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `a1` | 625-1 |
| acer-swift | `herman` | dashboards lane (#525, #523), not this week's list |
| msi-ms7758 | `m1` | 624-d, 624-e |
| msi-ms7758 | `m2` | skills#140 |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

msi and asus have no `gh` login: workers push branches over SSH and the lenovo session opens and merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634.

## Open owner gates

- Token-spend benchmarks: #625 on/off, #626.

## Merged this week

- nixos-config: #629 alert inventory, #630 asus workers, #632 and #636 annotation contract, #633 acer and msi slots,
  #634 journal-metrics wants alloy, #635 Claude sessions keep a working shell across a deploy
- skills: #141 role context (#138), #142 execution field (#130), #143 metrics analyst (#139)
