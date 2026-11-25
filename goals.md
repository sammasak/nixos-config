# Goals: one priority queue

The direction this queue serves: [vision.md](vision.md). Pruned and re-ordered on 25 Nov 2026 by the planning
lead. What shipped before is in git history and in the closed issues, not here.

## How we work (owner, 23 to 25 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break (main red, DNS, data at risk) jumps the queue.
- No dedicated benchmarks. Ship behind a switch scoped to one host, slot or model and compare on the running system.
- Every queued item names four things: the outcome a user sees, one metric read on the running system, a regression
  alert or guard, and a narrow quality gate of minutes. The scheduled full gate on main (acer, four times a day)
  covers the batch; no long gate per change.
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send`), never to Herdr panes. The one
  exception is the agent `paddock` on asus, which needs the GPU.
- Night is reduced capacity, not a pause. msi and asus are off 21:00 to 08:30 and are never woken; acer and lenovo
  keep working the queue.
- Prefer upstream nixpkgs modules and built-in features over home-made services.
- Owner gates: none, except what no agent can do (physical access, a real-terminal sudo, spending money, an
  account-level credential). Those carry the label `needs-owner` and are listed at the end.

## What "more work done" means

One definition for the whole queue, tracked by [#806](https://github.com/sammasak/nixos-config/issues/806):

| Measure | Read on 25 Nov, 12:10 UTC |
|---|---|
| Merged pool changes per day, by agent and model | 37 in about 22 h, all Claude; Pi 0, Codex 0 |
| Cost per merged pool change | mean 3.82 USD, median 1.66 USD (141.23 USD over 37 merged sessions) |
| Local share: local-model tasks merged with no hosted model writing the code | 0 of 0 |
| Pull requests merged, all repositories, 7 d (`shipping_prs_merged`) | 254 |
| Lead time, dispatch to merge | p50 0.47 h, p90 4.6 h |

## Queue, in pick-up order

| # | Item | Outcome | Metric (25 Nov) | Alert or guard | Quality gate (minutes) |
|---|------|---------|-----------------|----------------|------------------------|
| 1 | Main is green ([#624](https://github.com/sammasak/nixos-config/issues/624) tail) | the scheduled gate on main passes, so a batch of merges is known good | `homelab_scheduled_gate_red` = 1 (step `nixos-flake-check`, head `24964ca3c669`, 17 failures of that step counted) | `ScheduledGateRed`, `RetroDueStepFailsRepeat` (both firing) | rerun the one red step on acer: `NIXOS_STEP=nixos-flake-check devenv tasks run nixos:step` |
| 2 | Pi runs in a slot ([#620](https://github.com/sammasak/nixos-config/issues/620)) | `exec-pool submit --agent pi` completes a real two-line task | `exec_pool_attempts{agent="pi",state="succeeded"}` = 0; 2 failed in 5 s on 25 Nov before any model was reached | a runner test that the attempt's home holds Pi's config; the canary as a daily task once green | `just pool-merge-check BRANCH` (about 3 min), then the canary task on acer |
| 3 | A tool-capable local model on asus ([#494](https://github.com/sammasak/nixos-config/issues/494)) | the gateway routes Pi's tool loop to a model on the asus GPU | gateway requests served by asus, 7 d: 0 (`homelab.llmGateway.asus.enable` set on no host); project pi: 308 requests, all hosted free models | the gateway's provider health rule; `tool_capable` stays off for a model that fails the canary | the #620 canary on that model through the gateway; the catalog test |
| 4 | Work-done ledger ([#806](https://github.com/sammasak/nixos-config/issues/806)) | the dashboard shows merged changes and cost per merged change by agent and model | the table above; the session report has no model; cost reported for 114 of 143 turns | `PoolCostPerMergedChangeHigh` (3 d mean above 8 USD, at least 10 merged) | exec-pool unit test in `just pool-merge-check`; one look at the table after deploy |
| 5 | Local-model lane ([#807](https://github.com/sammasak/nixos-config/issues/807)) | small real tasks from any repository are finished by Pi on a local model and merged | local share 0 of 0; the 19 Nov pilot failed 1 of 1 | `LocalLaneRescueHigh` (share under 30 percent over 7 d, at least 10 tasks) | the task gate below, run on fixtures: one good and three bad results |
| 6 | Paddock serves over HTTP ([#508](https://github.com/sammasak/nixos-config/issues/508)) | the 35B MoE model answers chat requests on asus and the gateway routes to it | not served; harness on the disk path: 9.6 tok/s decode, 20.3 s to first token, GPU peak 7271 MiB | gateway provider health; a tokens per second floor after a week of use | one `curl` chat completion on asus, then the #620 canary |
| 7 | A slot changes only its own branch ([#653](https://github.com/sammasak/nixos-config/issues/653)) | a task cannot push or open a pull request outside `pool/<task id>` | push filter on for acer only; `privateUsers` on for msi's 4 of 7 slots; refused pushes per day not read | `execution-pool-vm` boots slots with `privateUsers`; filter fixtures | `just pool-merge-check BRANCH`; one passed and one refused push on the host |
| 8 | Pool findings ([#646](https://github.com/sammasak/nixos-config/issues/646)) | a session never sits unseen and a deploy does not block claims | `exec_pool_sessions_stalled` = 0; `turn_error` 12 and `host_draining` 11 transitions in total; slots quarantined 0 | the nine `ExecPool*` rules | `just pool-merge-check BRANCH`; the finding seen gone in its signal after deploy |
| 9 | Alerts that name what to do ([#624](https://github.com/sammasak/nixos-config/issues/624)) | every page names its command; an alert starts its own investigation | 3 alerts firing, 82 rules loaded; `homelab_alert_investigations_total` = 0 started; acer's slots query Prometheus, Alertmanager and Loki read only once PR #802 deploys (black-pi, then acer; msi's slots not yet) | the annotation contract check; `AlertInvestigationFailed`, `AlertInvestigationsStale` | the rule fixture tests; read the next 14-day firing list |
| 10 | Live comparisons ([#625](https://github.com/sammasak/nixos-config/issues/625), [#626](https://github.com/sammasak/nixos-config/issues/626)) | Shunt and the 300K compaction window are kept or dropped on read numbers | Shunt hooks about 10 ms per Bash call; cost per turn per arm not comparable yet (fewer than 20 turns per arm) | `ShuntHookOverhead`, `ShuntCollectorStale`, `ExecPoolCompactionWindowCostlier` | none to run: read both tables on 2 Dec and decide |

Items 2 to 6 are the local inference line (epic [#491](https://github.com/sammasak/nixos-config/issues/491)), which
the owner weighs high: local models on asus feeding the pool so Pi agents take real work beside Claude and Codex.
Item 6 runs beside the others on asus (agent `paddock`, branch `asus/ssd-expert-backing` of sammasak/paddock) and
takes no pool slot. Item 1 is first because every other merge leans on a green main.

### Quality gate for a local-model task

All machine-checked, under 5 minutes, and it never takes the model's word:

1. A check prepared by a hosted agent fails on the base and passes on the head, run by the gate.
2. The check file is byte-identical to the prepared one.
3. The diff touches only the files in scope and at most 60 changed lines.
4. The repository's fast lints pass.
5. One cheap hosted review that may only say "unsafe" or "does not fix the problem".

Fail: one retry with the check's output. Second fail: a hosted agent finishes it and the task counts as rescued.
A model keeps the lane while its local share holds 50 percent or more after 20 tasks.

First task supply (small, clear acceptance): herman#57, #62, #75, #76; llm-gateway#95 and #69; factum#61;
devenv-platform#141 and #129; pi-harness#26.

### What the slots showed on 25 Nov

- Pi, one-shot on acer, no model: failed in 5 s, "No API key found for the selected model".
- Pi with `--model homelab/auto`: failed in 6 s, model not found. Likely cause: the attempt's home has no Pi `models.json`
  (the workers module copies it into the guest user's home at activation, not into the attempt workspace).
- Codex: `submit` refused, no slot offers Codex. It needs an API key
  ([#808](https://github.com/sammasak/nixos-config/issues/808), `needs-owner`).
- Claude: 55 sessions, 37 merged, the numbers in the table above.
- `increase()` over `exec_pool_session_cost_usd_total` over-reads (576 USD for a day whose sessions sum to 153 USD);
  read cost from `exec-pool sessions` until #806 fixes the series.

## Open pool findings (item 8, in pick-up order)

1. A turn whose input never reached the agent is queued again at once, skipping the error backoff, and never counts
   as stalled.
2. The drain starts before the build, so a long build keeps a host from claiming.
3. Sessions lost turns to the 30 minute limit on 24 Nov; re-check the limit now that turns are interactive and park
   on idle.
4. A runner restarted mid-turn takes its new start as the turn's, so a subagent from before the restart is not seen.
5. A second session stalling on the same host and reason pages nothing new.
6. lenovo cannot push nixos-config (stale devenv gate); its root rebuild trigger needs a GitHub SSH key for root.
7. Re-measure lenovo's user slice now that the named workers are pool slots.
8. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.
9. Slot memory kills (PR #805, merged; deploy to acer and msi not confirmed): the slots share one
   `environments.slice` limit, so four heavy evaluations at once still kill one, and a kill that leaves the agent
   running is told to it only through its command's exit.
10. msi's `ownRefsOnly` push filter (PR #805) is live only after the msi deploy; read acer's push filter journal (one
    `passed`, one `refused`) before it.

Credential items moved to #653 (item 7).

## Later (not queued; pick up when the queue above is short)

- [#611](https://github.com/sammasak/nixos-config/issues/611): native OTLP metric requests above the 1 MiB limits.
  Metric: relay rejections per day, not read. Gate: the relay's fixture test.
- [#14](https://github.com/sammasak/nixos-config/issues/14): AdGuard's DNS ports by an explicit rule. DNS must stay up.
- skills#128 (one cheap review for small changes), skills#104, skills#107.
- [#600](https://github.com/sammasak/nixos-config/issues/600) stays the milestone that items 1, 9 and 10 report to.
- herman is parked for the platform sprint, except the small tasks in the lane's supply.

## Horizon (direction only, no work scheduled)

- The pool as a coding platform: any repository, guest users (vision.md).
- The app platform, epic [#557](https://github.com/sammasak/nixos-config/issues/557): next real step is to register
  one real app. Apps in the registry today: 0.
- devenv-platform#156 to #166, workload orchestration research: labelled `horizon`. vision.md names no container
  orchestrator; it moves up only when a real workload exists that the pool and systemd units cannot place.

## needs-owner (what no agent can do)

| Issue | What is needed |
|---|---|
| [#808](https://github.com/sammasak/nixos-config/issues/808) | an OpenAI API key with a spending limit, so Codex can run in the pool |
| [#653](https://github.com/sammasak/nixos-config/issues/653), slice 4 only | a GitHub App and its key, for per-task tokens |
| [#645](https://github.com/sammasak/nixos-config/issues/645) | boot the gaming entry on asus once, at the machine and the TV |
| [#601](https://github.com/sammasak/nixos-config/issues/601), PR #616 | a physical reboot of black-pi for the kernel fix |
| [#474](https://github.com/sammasak/nixos-config/issues/474) | naked-pi: the step named on the issue, before its next deploy |

## Hosts and slots

Placement order: acer, then msi, asus last (it carries ollama, Paddock and the GPU).

| Host | Slots | Note |
|------|-------|------|
| acer-swift | `pool1` to `pool3` | Shunt on for `pool1`, a 300K compaction window for `pool2`; offers claude and pi |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30 |
| asus-b460m | none | ollama (one resident model, 130 W cap), agent `paddock`; off 21:00 to 08:30 |

No slot holds a GitHub key: slots push through acer's GitHub sidecar and private clones go through the proxy.
Gaming entries on asus and msi are merged and booted on neither host yet; the owner accepted them untested (#645).
