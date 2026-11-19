# Measured fleet improvements

Tracking: [#600](https://github.com/sammasak/nixos-config/issues/600), under the existing [portfolio #295](https://github.com/sammasak/nixos-config/issues/295).
This covers every supported NixOS profile and its services. A green scrape target does not establish coverage or correctness.
The initial [baseline](records/monitoring-baseline-2026-11-19.md) records observed values and missing evidence.

## Repeat the baseline

From a machine allowed to query the existing receivers:

```bash
python3 scripts/monitoring-baseline.py \
  --prometheus-url http://192.168.10.137:9090 \
  --loki-url http://192.168.10.137:3100 > baseline.json
```

The snapshot preserves query text, evaluation time, API warnings and empty results. A query error exits nonzero while preserving other results.
An empty result is unknown until its cause is established: no events, missing instrumentation, disabled feature, sleeping host or failed collection.
`failed_units` is an exception: an empty filtered result means none were observed only if node scrapes and systemd collection succeeded.
Journal keyword matches are search leads, not an error-rate metric. Prefer producer event/status classifications.
`avg_over_time(up[24h])` includes planned poweroff; use the existing planned-off rules for sleeping hosts, and sample counts/known-on windows for availability claims.
Textfile age is interpreted per producer: `nixos.prom` changes at activation, while DNS and edge files refresh periodically.

## Coverage and ownership

| Area | Existing evidence | Next measurement/acceptance | Owner |
|---|---|---|---|
| Host capacity | Node CPU, RAM, root disk, pressure, OOM, sensors | CPU accounting validity before tuning; known-on availability and boot/login/suspend evidence per applicable host | #600, #601, #295 |
| RF lab | Separate naked-pi host profile, outside `sam.fleet.hosts` | Explicit RF-lab monitoring/availability decision; do not silently call all six profiles covered by five node targets | #600, #474 |
| Unit reliability | Failed units, timer triggers; restart counts enabled in source by this change | Observe restart counter receipt on all five fleet hosts; automatic restarts exclude manual starts | #600 |
| Telemetry pipeline | Prometheus/Loki/Alloy health, series, resident RAM, textfile errors | Delivery lag/drop/retry coverage for each host's journal writer; protect existing privacy filters | #600, #602 |
| Essential services | Seven public probes, Caddy/Authentik/DNS and gateway metrics | A successful auth redirect/401 proves the edge path, not authenticated end-to-end functionality | #563, #14 |
| Stateful recovery | Backup/restore units and timers | Last successful backup, age, duration, verified restore, RPO/RTO per stateful app; a timer trigger alone is insufficient | #564, #565 |
| Gates and sandboxes | Per-step outcomes, durations, host and check; Shipping/Navigation | Queue wait, sample counts and seven-day per-unit CPU attribution; bounded collector overhead | #535, #596 |
| Deployment | Generation, lag, duration, rollback and failed-unit records | Failed activation/reboot/concurrent promotion and recovery proofs | #565, #558 |
| Apps | Existing registry and ingress | First and second independent app delivery; requests/errors/latency and process health for each admitted service | #560, #563, #566 |
| Inference | GPU power/VRAM/temp/throttle, benchmark scorecards and gateway outcomes | Matched MSI/gateway runs, contention and model digest/context attribution | #493, #491 |
| Agent quality | Pi events, tool outcomes, checks, issue outcomes, reviews | Direct ASUS path emits safe correlated events; verified patch/check/review/intervention distinct from self-reported pass | #494 |
| Daily operation | Existing daily and fortnightly coordinator reports | Review this matrix and unknowns using current data; link each selected change and result to its owning issue | #600, #295 |

## Improvement loop

1. Read the existing Shipping, Fleet, Hosts, Pi Agents and inference dashboards, then run the snapshot. Check missing data and collector health before choosing a bottleneck.
2. Select an existing issue. For a new proven gap, open one issue with a baseline, hypothesis, affected hosts, expected benefit, acceptance query and revert condition. Link it from #600. Keep dependent work in its existing owner.
3. Change one cause at a time. Use matched workload, model digest, context and host load for performance comparisons; report sample counts and avoid percentile claims on tiny samples.
4. Run the owning checks and independent review. A dashboard query parsing successfully does not prove that its producer is deployed or emits data.
5. Activate on explicitly approved hosts through the existing deployment gate. Record source SHA, actual generation, affected units and first receipt. Sessions must be parked where required by the rollout procedure.
6. Compare the same observation window before/after, including failures and resource overhead. Retain only with evidence; revert on lost operational errors, privacy regressions, unavailable essential services, or violated workstream thresholds.
7. Add the result and remaining unknowns to the owning issue. Use the existing daily report and fortnightly review; timers rendering reports are not an autonomous permission to change hosts.

Existing thresholds stay authoritative: Shipping policy values in `modules/homelab/monitoring/shipping-policy.json`; #596's CPU attribution >=90%, extra memory <=100 MiB, <=3000 additional series, scrape <=2 s; offload abort at >1 job/day lost to shutdown. No threshold is relaxed to make a chart green.

The first iteration corrects physical-model charts using `served_model`, with requested-model/unknown fallback; adds missing-attribution, per-tool error and 3–24h unmatched-start views; and enables the existing systemd restart counter. It adds no exporter, listener or paging alert. Missing restarts remain unknown until host activation. Candidate orphans may be legitimate long runs or missing logs; they do not prove a live process.

CPU accounting diagnostics (#601) record `homelab:node:cpu_accounting_rate`: non-guest accounted CPU time per wall-clock core-second, expected near 1. Hosts displays the raw ratio, including values above 100%; the baseline also queries its source expression before activation. This does not fix the producer or normalize/clamp existing utilization. Tests cover normal accounting, impossible over-accounting, guest double-counting and missing idle data. No paging threshold is introduced.
