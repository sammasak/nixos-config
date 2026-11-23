# Weekly goals: 23–29 November 2026

Outcome: a working metrics → alerts → investigation → fix → verification loop, and the specialist agent roles
that run it. Small PRs, shipped by per-issue nspawn workers. Updated when a PR opens or merges, or a worker changes.

## Priorities

| P | Issue | Scope | State |
|---|-------|-------|-------|
| P0 | [#600](https://github.com/sammasak/nixos-config/issues/600) | Self-improvement milestone | source mostly merged; live receipts need host activations |
| P0 | [#624](https://github.com/sammasak/nixos-config/issues/624) | Actionable alerts | split below |
| P0 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt metrics, Grafana, alerts | split below |
| P1 | [skills#138](https://github.com/sammasak/skills/issues/138) | Thin global context, role context | wave 1 |
| P1 | [skills#130](https://github.com/sammasak/skills/issues/130) | Write-capable role contracts | wave 1, merges after #138 |
| P1 | [skills#139](https://github.com/sammasak/skills/issues/139) | Metrics analyst | after #138 |
| P1 | [skills#131](https://github.com/sammasak/skills/issues/131) | Incident investigator | after #138 |
| P1 | [skills#140](https://github.com/sammasak/skills/issues/140) | Improvement verifier | after #138 |
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | after #130 and #138 |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | after #130 and #138 |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | last: needs #139 plus #131 or #137 |
| P2 | skills [#132](https://github.com/sammasak/skills/issues/132), [#134](https://github.com/sammasak/skills/issues/134), [#135](https://github.com/sammasak/skills/issues/135) | Remaining specialists | when idle |
| P2 | [#626](https://github.com/sammasak/nixos-config/issues/626) | Auto-compaction benchmarks | matrix doc when idle; benchmark is token spend |

## Work items

### #624 actionable alerts

| Item | What | State | PR |
|------|------|-------|----|
| 624-a | Inventory: signal → rule → route → last receipt → gap | in progress (lenovo) | |
| 624-b | Annotation contract (summary, description, query, runbook) on the homelab rules, asserted by the check | assigned `a624` | |
| 624-c | OTLP relay rejection alert (the monitoring-blindness example) | queued | |
| 624-d | Journal-delivery stale alert | queued | |
| 624-e | Backup-completion stale alert | queued | |
| 624-f | Synthetic fire and resolve test through Alertmanager and alert-bridge | queued | |
| 624-g | Live delivery receipts | owner gate: black-pi and lenovo activation | |

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | in progress (lenovo) | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | queued | |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts | queued | |
| 625-pilot | Lenovo pilot, on/off benchmark | owner gate: lenovo activation, token spend | |

## Workers

| Host | Worker | Item | State |
|------|--------|------|-------|
| asus-b460m | `a624` | 624-b | to declare |
| asus-b460m | `s138` | skills#138 | to declare |
| asus-b460m | `s130` | skills#130 | to declare |
| acer-swift | `herman` | dashboards lane (#525, #523), not this week's list | busy |
| msi-ms7758 | `t1` | none: it holds no push credential | idle |

asus has no `gh` login: its workers push branches over SSH and the lenovo session opens and merges the PRs.

## Open owner gates

- Host activations for live receipts: #624-g, the #625 pilot, and the #600 children #601 (PR #616), #602, #611,
  #614, #615, #618.
- Token-spend benchmarks: #625 on/off, #626.
- Installing merged roles: `nix flake update skills`, then a switch.

## Merged this week

None yet.
