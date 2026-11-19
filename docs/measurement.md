# Measurement: what we keep, how it is read, when it is good enough

Four areas: the personal host, the app platform, the nspawn sandboxes with their harnesses, and the delivery and
review loop that builds them. Targets live as data in `metrics/targets.json`; this page says what each metric is
for. `nixos:measurement-test` (`scripts/test-measurement.py`, in `nixos:qa`) fails when the two disagree.
Coordinator reports, the weekly and daily ones, are described once in the skills repo:
https://github.com/sammasak/skills/blob/main/docs/measurement.md.

## The one path

`event -> platform record line -> Loki -> shipping-metrics exporter -> Prometheus -> dashboard + scorecard`

Records are written by `scripts/platform-record.sh` (`{job="platform"}` on black-pi, kept 30 days); guests ship
through `scripts/guest-records.py`; `scripts/shipping-metrics.py` adds GitHub data and exports `shipping_*`.
Dashboards are in `modules/homelab/monitoring/dashboards/`. No second stack.

## Rules

1. A metric exists only if it answers a named question and changes a decision. At most six per area.
2. Every metric has a question, a source, an exact query, a target, and the date the target last changed with the
   reading that justified it.
3. Targets live in `metrics/targets.json`, never in code. The test fails if a live metric has no query, no
   dashboard panel or no target.
4. An unknown reading is shown as unknown, never as a pass.
5. Every record kind has a maximum age (`max_age_hours`). A kind that has gone quiet is stale, so a collector that
   stopped is visible.

Starting maximum ages: 96 h for the kinds every `nixos:qa` or a daily timer writes (a weekend with the
power-windowed hosts off stays fresh), 336 h for `deploy` and `checks-run`, which come in bursts.

States: **live**, the source writes today, the query runs and a panel shows it; **in flight**, the source is
being built on a named branch or issue; **new**, no source yet. Only a live metric has a query: an in-flight or
new one reads as unknown until its source lands, and no metric name is written down before it exists.

## A. Personal host (msi desktop, asus, lenovo as laptop)

| Id | Question | Source | Target | State |
|---|---|---|---|---|
| `deploy-rollbacks` | Do deploys hold without a rollback? | `deploy` records | 0 rollbacks in 30 days | live |
| `failed-units-after-deploy` | Does a deploy leave a unit failed? | `deploy` records, `failed_units` | 0 on every node, last 7 days | live |
| `deploy-failures-caught-at-build` | Is a crash caught at build rather than at deploy? | `deploy` records, `coverage` records | every failed deploy of the last 30 days has a build-time check added | live |
| `morning-wake` | Do the hosts wake as planned? | node-exporter `up`, `homelab:node:planned_off` | 0 unplanned-down samples in 14 days | live |
| `boot-to-session` | How long from power-on to a usable session? | new: `systemd-analyze` textfile metric | stable within 10 % | new |
| `eval-time-closure` | Is the config getting slower or bigger? | `metrics/history.jsonl` (bench), not in Prometheus or Loki yet | no step above 10 % without a stated reason | new |

```
deploy-rollbacks: sum(sum_over_time({job="platform",kind="deploy"} | logfmt | unwrap rolled_back [30d])) or vector(0)
failed-units-after-deploy: max by (node) (max_over_time({job="platform",kind="deploy"} | logfmt | failed_units!="unknown" | unwrap failed_units [7d]))
deploy-failures-caught-at-build: sum by (node, result) (count_over_time({job="platform",kind="deploy"} | logfmt | result!="ok" [30d]))
morning-wake: count_over_time((max by (node) (up{job="node-exporter"}) == 0 unless on (node) homelab:node:planned_off)[14d:5m])
```

`deploy-failures-caught-at-build` lists the failures; whether each got a check is read by hand from the PRs.

## B. App platform (k3s replacement, #557)

| Id | Question | Source | Target | State |
|---|---|---|---|---|
| `registry-apps` | Are the apps delivered through the registry? | new: count from `apps/registry.json` vs apps in `modules/homelab` | all owner-chosen apps | new |
| `app-availability` | Are the apps up for their users? | blackbox `probe_success` | 99 % per public name over 14 days | live |
| `ships-without-code-change` | Does an app ship without a nixos-config code change? | new: PRs touching only `apps/registry.json` vs all app changes | 9 of 10 | new |
| `bump-to-live` | How long from a registry bump to live? | new: merge-to-deploy lag filtered to registry bumps (`shipping_deploy_lag_hours` is not) | under 30 min | new |
| `restore-proven` | Can each stateful app be restored? | new: `restore-test` record per stateful app (#564) | newest pass under 30 days old, every stateful app | new |
| `behind-authentik` | Is every public name behind Authentik? | new: a check per public name (only chat's redirect is probed today) | 100 % | new |

```
app-availability: avg by (instance) (avg_over_time(probe_success{job="blackbox"}[14d]))
```

Prometheus keeps 15 days (`modules/homelab/monitoring/prometheus.nix`), so availability reads 14 days, not 30.

## C. nspawn sandboxes and coding harnesses

| Id | Question | Source | Target | State |
|---|---|---|---|---|
| `guest-secrets-readable` | Can a guest read a secret? | sentinel VM test (`workers/secrets-sentinel-vm`) | 0, test green on every gate | in flight |
| `undeclared-connections` | Does a guest connect outside its declared list? | egress census (design on #564, owner enables) | 0 after the allowlist is enforced | in flight |
| `time-to-shell` | How long until a guest has a working shell? | new: record from the timing in `docs/records/environments-timings-2026-11.md` | warm under 10 s, fresh under 120 s | new |
| `verified-deliveries` | Does a handoff end verified? | `delivery` records count verified deliveries; new: handoff count (the coordinator audit log stopped 14 Nov) | 8 of 10 handoffs | new |
| `first-pass-by-harness` | Which harness and model pass review first time, and which task classes are worth offloading to Pi? | new: `review` record, with `agent-harness` cost and tokens; per task class, `offload` record (`workers/offload-kind`) | known per harness, trend not falling; per task class, offload only where the rate beats the threshold in the pi-offload skill's `advice.json` | new |
| `resource-per-task` | What does a guest task cost in resources? | usage record (#494) | recorded for 9 of 10 guest handoffs | in flight |

## D. Delivery and review loop

| Id | Question | Source | Target | State |
|---|---|---|---|---|
| `rounds-to-pass` | Are briefs and authors good enough? | new: `review` record (`shipping_review_rounds` exists but no PR carries a grade it can parse) | median 1, 90 % at 2 or fewer | new |
| `review-turnaround` | Is the reviewer a bottleneck? | new: `review` record | median under 15 min | new |
| `gate-red-after-pass` | Does review miss what the gate catches? | new: `review` record joined with `gate` records | under 1 in 10 | new |
| `escapes` | Does the loop let defects through? | `shipping_escapes` (reverts, `escape` issues), `shipping_prs_merged` | under 1 in 20 merges, 7 days | live |
| `finding-yield` | Where is review worth its cost? | new: `review` record findings per risk tier | drives review depth in `docs/records/shipping-risk-tiers.md` | new |
| `worker-idle` | Are eligible workers kept assigned? | new | under 20 % of working hours | new |

```
escapes: sum(shipping_escapes{window="7d"}) / sum(shipping_prs_merged{window="7d"})
```

## Research procedure

One issue per topic, titled `[Research] <topic>`, with the body used on #591:

1. Questions, each tied to one of the four areas.
2. First-pass survey by a subagent: input, not a result.
3. Verification against the primary source at a pinned commit; corrections listed.
4. Mapping to what our modules have today, with file references.
5. Scoring on the fixed rubric: problem we have, cost, build-time checkable, security effect, observability,
   reversibility.
6. Independent evaluation by an agent that did not write the note.
7. Decision comment: adopt, spike or reject per idea. A spike has a measurable output and a reject condition, and
   continues on an existing issue; its outcome is followed up at 30 days.

At the decision a `research` record (new) keeps claims checked and corrected, hours from open to decision, and ideas
adopted, spiked and rejected. Backlog: fc-nixos (area B), clan and srvos (A), microvm.nix (C).

## Adding or retiring a metric

Add: name the question and the decision it changes; add its row here and its entry in `metrics/targets.json` in
the same commit, with `target_changed` saying where the target came from. A live metric names the dashboard panel
that shows it (`panels`); a new record kind gets its `max_age_hours`. An area already at six retires one first.

Retire: remove the row and the entry together; the commit says which decision no longer needs it.

Change a target: edit `target` and `target_changed` (date and the reading behind it) in one reviewed commit.
