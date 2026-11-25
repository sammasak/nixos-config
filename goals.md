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
  alert or guard, and a narrow quality gate of minutes. The scheduled full gate on main (acer, twice a day, see Check tuning)
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
| 1 | Main is green ([#624](https://github.com/sammasak/nixos-config/issues/624) tail) | the scheduled gate on main passes, so a batch of merges is known good | `homelab_scheduled_gate_red` = 1 after the 15:20 run (step `nixos-flake-check`, head `85ea6e5f722b`). The red is `checks.grafana-dashboards`: `exec_pool_memory_kills_total` (4406fe2e) and, on later main, `codex_egress_*` (41766502) are selected by exec-pool.yaml rules but read from no source the check knows; fixed on main by #814 (1551a33c, 07e398c2), a check change, no host moves; #815 adds the merge check. The 19:20 run (head `05c028bbad89`) is red at the same step for another cause: `legacyPackages` (703d2e8a, `pkgsDir`) is a flake output kind the step's list lacked; fixed by the output-kinds branch, no host moves | `ScheduledGateRed`, `RetroDueStepFailsRepeat` (both firing) | `nix build .#checks.x86_64-linux.grafana-dashboards` (about 7 min on msi), then the next scheduled run |
| 2 | Pi runs in a slot ([#620](https://github.com/sammasak/nixos-config/issues/620)) | `exec-pool submit --agent pi` completes a real two-line task | `exec_pool_attempts{agent="pi",state="succeeded"}` = 0; 2 failed in 5 s on 25 Nov before any model was reached; fix in #811 (`PI_CODING_AGENT_DIR`; by hand in acer `pool3`: exit 0 on `homelab/auto`), needs a deploy of acer-swift | `nixos:workers-eval-test` checks that the step's env names the dir holding Pi's `models.json`; the canary as a daily task once green | `just pool-merge-check BRANCH` (about 3 min), then the canary task on acer |
| 3 | A tool-capable local model on asus ([#494](https://github.com/sammasak/nixos-config/issues/494)) | the gateway routes Pi's tool loop to a model on the asus GPU | gateway requests served by asus, 7 d: 0 (no host enabled the provider; its gemma4 entry was not `tool_capable`); project pi: 308 requests, all hosted free models. This item's PR enables it on acer with `qwen3.5:4b` first in tier 3 (`local`, and `auto` once every cloud model is out), msi's llama3.1 text-only; owed, in this order: `ollama pull qwen3.5:4b` on asus (or `homelab.ollama.toolModel.enable` and a deploy of asus), then a deploy of acer-swift; deployed first, the first `local` tool call 404s and blocks the model for 6 h | the gateway's provider health rule; set `tool_capable = false` in `llm-gateway-asus.toml` if the canary fails | the #620 canary with `--model homelab/local` through the gateway; `checks.llm-gateway-asus` |
| 4 | Work-done ledger ([#806](https://github.com/sammasak/nixos-config/issues/806)) | the dashboard shows merged changes and cost per merged change by agent and model | the table above; cost reported for 114 of 143 turns; [#814](https://github.com/sammasak/nixos-config/pull/814) adds the model, one-shot tasks, the "Merged changes per day" table and the exact cost counter, needs a deploy of acer-swift (queue, migration 24) and black-pi (dashboard, Loki rule); `rescued` and local share still open (the runner must record the head it pushed); the same PR fixes `grafana-dashboards` on main (it missed `exec_pool_memory_kills_total`) | `PoolCostPerMergedChangeHigh` (3 d mean above 8 USD, at least 10 merged) | exec-pool unit test in `just pool-merge-check`; one look at the table after deploy |
| 5 | Local-model lane ([#807](https://github.com/sammasak/nixos-config/issues/807)) | small real tasks from any repository are finished by Pi on a local model and merged | local share 0 of 0 (pi-agents "Local-model lane" table, from the `local-lane` record); the 19 Nov pilot failed 1 of 1. The lane is `scripts/local-lane.py run` (gate, one retry, record) with tasks in `scripts/lane-checks/`; its first real runs are owed (PR #816 comment has the commands): on 25 Nov 17:05 `homelab/local` answered 429, "asus/qwen3.5:4b blocked", and no slot has `exec-pool` | `LocalLaneRescueHigh` (share under 30 percent over 7 d, at least 10 tasks), not written yet: a Loki rule over the `local-lane` record | `nixos:local-lane-test` (about 15 s): one good and the bad results, and `run` against a fake pool |
| 6 | Paddock serves over HTTP ([#508](https://github.com/sammasak/nixos-config/issues/508)) | the 35B MoE model answers Pi's tool loop on asus through the gateway | `llm_gateway:paddock_requests:increase1d{outcome="ok"}`: 0 (not deployed); by hand on asus, 127.0.0.1:11540: 27 to 30 tok/s decode, 0.8 s to first token, tool calls well formed. This item's PR declares `homelab.paddock` on asus (on in its host config; Ollama on the CPU while it runs) and puts `asus-paddock/Qwen3.6-35B-A3B-UD-Q4_K_XL` first in tier 3 (`local`); owed, in this order: stage the GGUF at `/var/lib/paddock-models/`, stop the hand-run user unit, deploy asus-b460m (coordinator's go: a worker runs there), then acer-swift, whose gateway holds the catalog; while it is on Paddock owns the GPU and `asus/qwen3.5:4b` is not pulled | the gateway's health probe on `/healthz` (stopped or off: `local` falls to Ollama's `qwen3.5:4b`, then refuses tools); `tool_capable = false` in `llm-gateway-asus.toml` if the canary fails | `checks.llm-gateway-asus`, `monitoring-rules-tests`; after both deploys one `curl` tool call to `local` through the gateway (PR #817), then the #620 canary with `--model homelab/local` |
| 7 | A slot changes only its own branch ([#653](https://github.com/sammasak/nixos-config/issues/653)) | a task cannot push or open a pull request outside `pool/<task id>` | push filter on for acer and msi (PR #805); `privateUsers` on for msi's 4 slots, and with this item's PR for acer's 3 (7 of 7 once acer-swift is deployed); refused pushes per day: `sum by (node) (increase(exec_pool_push_filter_pushes_total{result="refused"}[1d]))`, read once acer-swift and msi-ms7758 are deployed. Open: a pull request's head is not held to the task's branch (a body-reading gate), and slice 4 (GitHub App, needs-owner) | `ExecPoolPushesRefused` (3 refusals from one slot in an hour, not one); `execution-pool-vm` boots slots with `privateUsers`; the filter fixture counts one refused push | `just pool-merge-check BRANCH`; one passed and one refused push on the host, its `refused` count up by one |
| 8 | Pool findings ([#646](https://github.com/sammasak/nixos-config/issues/646)) | a session never sits unseen and a deploy does not block claims | `exec_pool_sessions_stalled` = 0; `turn_error` 12 and `host_draining` 11 transitions in total; slots quarantined 0 | the nine `ExecPool*` rules | `just pool-merge-check BRANCH`; the finding seen gone in its signal after deploy |
| 9 | Alerts that name what to do ([#624](https://github.com/sammasak/nixos-config/issues/624)) | every page names its command; an alert starts its own investigation | 3 alerts firing, 82 rules loaded; `homelab_alert_investigations_total` = 0 started: lenovo's trigger ran (`up` 1) but only `NodeSystemdUnitFailed` was switched on, so ScheduledGateRed, RetroDueStepFailsRepeat and ExecPoolSlotMemoryKills were never candidates. This item's PR switches them on in `modules/homelab/alert-investigations.json` (one session per firing, 3 per name a day, report on issue `Alert: <name>`), black-pi's page for them gains an `Investigation:` link to that issue, and the prompt lets the session read Prometheus, Alertmanager and Loki where its slot can; owed: deploy lenovo and black-pi, then read `started` | the annotation contract check; `AlertInvestigationFailed`, `AlertInvestigationsStale` | the rule fixture tests; read the next 14-day firing list |
| 10 | Live comparisons ([#625](https://github.com/sammasak/nixos-config/issues/625), [#626](https://github.com/sammasak/nixos-config/issues/626)) | Shunt and the 300K compaction window are kept or dropped on read numbers | read 25 Nov 17:00 UTC from an msi slot (route works), arms labelled since 25 Nov 09:30, about 7.5 h: acer pool3 default 13 turns, 0.19 USD and 2.06M tokens per turn; pool2 300K 12 turns, 0.15 USD, 3.27M tokens, 1 auto compaction; pool1 Shunt 8 turns, 0.89 USD, 3.68M tokens, but Shunt acted on none (5 spill checks, all `small`, no redirect), so its gap is task mix; Shunt hooks 11 ms per Bash call on lenovo, 16 ms on pool1; turn errors (12 in total) carry no arm label. Too thin, switches stay: the window needs one full day with 10 turns a side (from 26 Nov 10:10), Shunt 20 turns on pool1 with at least some spills or redirects (about 2 more session-days) | `ShuntHookOverhead`, `ShuntCollectorStale`, `ExecPoolCompactionWindowCostlier` (none firing) | none to run: read the window table after 26 Nov 10:10 UTC, Shunt by 2 Dec, and decide |

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

How it runs (`scripts/local-lane.py`, #807): the hosted agent writes the check as a Python file in
`scripts/lane-checks/`, red on the target's main. `run` proves it red there, submits `exec-pool submit --agent pi
--model homelab/local` with the check's source in the prompt, waits, fetches `pool/<task>`, gates it with its own copy of
the check, retries once with the gate's output, and writes one `local-lane` record (model, repo, result, the item that
failed, attempts, lines, seconds; the task id only in the line). A check committed in the target tree works too
(`--check` with `--check-file`), but llm-gateway and herman refuse to push a fresh tree there: llm-gateway's pre-push
asks for a green `sdlc:done`, whose review stage needs a verdict, and herman's runs its full `rust:ci`. The same hook
meets Pi's own push, so a task in those repos can fail at `push` until a `pool/*` push skips that gate (owner's call).
Prepared and proven passable on 25 Nov: `nixos-config-bench-qwen` (docs), `herman-75` (#75), `llm-gateway-95a` (#104,
#105) and `llm-gateway-95b` (#95).

### What the slots showed on 25 Nov

- Pi, one-shot on acer, no model: failed in 5 s, "No API key found for the selected model".
- Pi with `--model homelab/auto`: failed in 6 s, model not found. Cause, confirmed in acer `pool3`: the attempt's home
  has no Pi `models.json` (the workers module copies it into the guest user's home at activation, not into the attempt
  workspace).
- Codex: `submit` refused, no slot offers Codex. #808 runs it on the owner's ChatGPT login, the `codex login` as lukas
  on acer (`sam.workers.codexAuthFile`, PR #812): after acer's deploy, the glance and one canary task
  (docs/records/execution-pool-credentials.md, Codex), a usage-limit 429 until the quota returns on 26 Nov 23:28.
  Metric: `exec_pool_attempts{agent="codex",state="succeeded"}`, 0 today, and
  `host_status:codex_egress_refusals:count1m`. Gate: `nixos:codex-egress-test` and the canary.
- Claude: 55 sessions, 37 merged, the numbers in the table above.
- `increase()` over `exec_pool_session_cost_usd_total` over-reads (579 USD for a day whose sessions sum to 156 USD):
  Postgres summed the float8 costs in a varying order, the total dropped by its last bit (`70.66159840000003` to
  `...02`) and Prometheus read each drop as a reset, 7 in 2 days. #806's branch sums them as numeric; read cost from
  `exec-pool sessions` for any range before acer runs it.

## Open pool findings (item 8, in pick-up order)

1. ~~Sessions lost turns to the 30 minute limit~~: on 25 Nov Prometheus counted 51 `turn_timeout` parks against 68
   `turn_end` (acer 34, msi 17), one session stalled after three in a row. A pane turn's limit now restarts on every
   write to its transcript or a subagent's and while it waits on its own background job, bounded at four limits with
   no pause (`runner_main::limit`): a cut is a turn silent for 30 minutes or busy for two hours, and still continues
   by itself up to three in a row. Live after deploys of acer and msi.
2. ~~A runner restarted mid-turn takes its new start as the turn's~~: no longer holds. The turn's start and its
   subagent check live in the helper (`exec-pool-exec@`, `restartIfChanged = false`), which a restarted runner
   adopts and does not restart; a restarted helper refuses the run (its run directory exists).
3. lenovo cannot push nixos-config (stale devenv gate); its root rebuild trigger needs a GitHub SSH key for root.
4. Re-measure lenovo's user slice now that the named workers are pool slots.
5. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.
6. Slot memory kills (PR #805, merged, deployed and confirmed on acer, msi and black-pi): the slots share one
   `environments.slice` limit, so four heavy evaluations at once still kill one, and a kill that leaves the agent
   running is told to it only through its command's exit. ExecPoolSlotMemoryKills (issue #827), read from a slot in
   Loki's kernel task dumps: at 16:41:43Z and 18:14:24Z on 25 Nov pool1's push hook `nix flake show` (light lock, 3.2
   and 3.0 GiB) ran beside another slot's `pool-merge-check` host evaluation (heavy lock, 2.5 and 2.2 GiB), plus a
   0.7 GiB devenv evaluation at 18:14: two heavy evaluations in one slice, each under a different lock. Fixed on
   pool/cli-f562005cb177dad6: pool-merge-check evaluates under the heavy lock and then the light one, and builds under
   the heavy one alone (live on merge, no deploy). acer-swift's deploy adds `homelab_guest_memory_bytes{worker}`,
   `_peak_bytes` and the slice's current and limit, every minute; the runbook has the slot's Loki query. Signal:
   `exec_pool_memory_kills_total` flat on acer over a day of merges. Follow-ups: evaluations outside both locks still
   share the slice (a devenv shell's evaluation, an agent's own `nix eval` or `nix build` of a host or check; the
   prompt or a wrapper could send them through the light lock); acer's 7G stays (15 GiB, ollama 4G).
7. msi's `ownRefsOnly` push filter (PR #805) is live only after the msi deploy; read acer's push filter journal (one
   `passed`, one `refused`) before it.

Fixed on pool/cli-fc35c75b867a1608, live after deploys of acer (the queue, migration 25, its textfile and runner),
msi (its runner parks through `hold_input`) and black-pi (the alert rule); `just deploy` is the repo's own: an undelivered turn's input is held for the error backoff and past it
counts as stalled (`an_undelivered_turn_keeps_the_error_backoff_and_past_it_counts_as_stalled`); `just deploy`
builds the toplevel before the drain (`scripts/test-deploy-recipes.py`, `scripts/test-system-checks.py`); each
stalled session pages on its own (`exec_pool_session_stalled`, the rule test in `modules/homelab/monitoring/rules/tests/exec-pool.yaml`).

Credential items moved to #653 (item 7).

## Check tuning

Owner, 25 Nov: "keep count of how we can fine tune testing so that we can have some small and fast checks applied and
only run long gates even less often". The tally below covers 11 to 25 Nov. Sources: git history (871 commits, 260
merged pull requests), pull request bodies, the code's own measured comments, and this file's earlier entries. Per-step
seconds and run counts sit in Loki's `{job="platform",kind="gate-step"}` records, and a pool slot cannot reach Loki or
Prometheus (both time out), so most minutes below read **unknown**. Read them on lenovo or acer with
`{job="platform",kind="gate-step"} | logfmt | gate="nixos-qa"`, or for the merge check `gate="pool-merge-check"`.
"Caught" means a fix commit or pull request names the check as what failed. A lint finding fixed in the same branch
counts as a catch, but not as a host defect.

### The full gate (nixos:qa) and the merge check

Runs: nixos:qa ran on every push until 24 Nov 09:19 (63db4216). The count is unknown: there were 381 first-parent
commits on main from 11 Nov to then. Since that time it runs only as the scheduled gate (acer, 03/09/15/21:20, only
when main moved) or `just full-gate`. That allows at most 4 scheduled runs, from 24 Nov 15:20 to 25 Nov 09:20, and
main moved before each one. `just pool-merge-check` exists since 24 Nov: 16 of the 93 pull request bodies merged since
then cite it.

| Check or step | Typical minutes | Runs in 14 d | Real defects caught (commit or PR) | Depends on |
|---|---|---|---|---|
| Whole scheduled gate | 37.6 (first run, 2256 s on acer, 24 Nov); the unit comment says 20 to 40 | at most 4 | 3 reds: `shunt-metrics-test` (a stale guest name after #748, fixed df0f5007 in #759), `execution-pool-vm` failing to evaluate (#795), `grafana-dashboards` on two rule names it found no source for (fixed in #814) | everything |
| lint-comments, lint-shell, deploy-rs-pins | unknown, seconds | every push (pre-push fast set) | lint-comments: 9d7cec2a (#800, a path read as a pointer); shellcheck: d947c2a2 (#795) | `.nix`, `.sh`, `.py` comments; `scripts/*.sh`; devenv.yaml, devenv.lock, flake.lock |
| fmt-check | unknown | every full gate | 747a1f71 (#684, an unformatted line) | every `.nix` |
| secrets-verify | unknown, seconds | every push | none traced | `secrets/` |
| nixos-push-eval (`nix flake show`) | about 1.5 (90 s, 3.9 GiB, acer) | every push | 24cb9892 (#797): #793 and #796 both defined the VM's gh stub, so main's evaluation failed. Seen on main, after both merged | every flake output's attribute set, no check derivation |
| gate probe (every host evaluated once) | unknown | every full gate | none traced: the tests' failures are named below | every host |
| nixos-flake-check | unknown, the bulk of the 37 min | every full gate | `execution-pool-vm` evaluation (284ec013, #795); package check phases: scheduled-gate ruff E501 (358dbb87, #787, after #785 failed acer's deploy build), exec-pool clippy and rustfmt (10 commits, e.g. 7576a436, 2a825331, 5a09c714) | every check and every x86 host |
| coordinator-test, worker-permissions-test, workers-eval-test, alloy-otlp-test (side by side on asus) | unknown | every full gate | workers-eval: 0b90b42d (#781, a slot rename that rewrote an instance case), f4fac5f5 (#736, msi's slot) | gate probe (every host), `modules/workers/`, `modules/programs/cli/claude-code/` |
| shunt-metrics-test | unknown | every full gate | the first scheduled red (df0f5007, #759) | probe, `scripts/shunt-metrics.py`, its test |
| typed-interfaces-test | unknown | every full gate | made green again in #731 (a test fix, not a host defect) | `modules/` |
| deploy-recipes-test | about 0.05 (2.8 s here) | every full gate | since #803 it fails on a `github:` private input, the class behind #798 | Justfile, flake.lock, `scripts/post-deploy-check.sh` |
| seventh-host-test | about 1.8 (110 s on asus, 18 Nov) | every full gate | none traced | hosts.nix, fleet.nix, every host |
| The other 38 tests in `tests` (devenv.nix) | unknown | every full gate | none traced in commit messages; the edits were test upkeep beside a feature | most read the gate probe (every host); the Nix-free ones read only their script |
| pool-merge-check: host evaluation | about 0.5 per host, about 3 for six; msi peaks at 4.2 GB | about 16 cited | lenovo's sam.memory budget (85ebfd25 in #794, 7d883001 in #799) | the host's modules and `hosts/<dir>/` |
| pool-merge-check: package build | unknown | about 16 cited | c15a3024 (#795, ruff E501 before merge) | `pkgs/<dir>/` |

### Escapes: what reached main or a deploy unseen, and the smallest check

| Escape | Seen at | Smallest check that would have caught it | Exists now |
|---|---|---|---|
| #792 broke lenovo's evaluation (sam.memory assertion) | deploy | lenovo's toplevel drvPath evaluated from the merge with main | yes: pool-merge-check evaluates every host for any unmapped path (#799) |
| Migration numbers clashed: #793 with #791, #797 with #793 | merge conflict | pool-merge-check against current main right before the merge (merge-tree exits 1 on a conflict), and the migration numbering (one name per number, no gap) | merge-tree yes, but only when rerun after the other PR merged; numbering check added in this branch |
| #798's skills pin bump returned a 404 on a private archive | deploy | every private input is git+ssh (`scripts/test-deploy-recipes.py`, #803) | yes, and pool-merge-check runs it for any flake.lock change (this branch) |
| `execution-pool-vm` failed to evaluate and wrote no check record, so the gate was red with nothing to act on | scheduled gate, red for about 18 h | an evaluation failure records its check (a359e3cb, #795) | the record yes. Evaluating the VM check's drvPath for `modules/workers/` changes does not exist yet |
| exec-pool.yaml rules selected `exec_pool_memory_kills_total` and `codex_egress_*`, which the dashboard check finds in no source (a `(name, help)` constant, a Python textfile writer) | scheduled gate (15:20, head 85ea6e5f) | `checks.grafana-dashboards`, about 7 min, for a rule YAML change | yes: pool-merge-check runs it for rule YAML (#815) |
| A host evaluation in a slot was killed for memory three times | pool-merge-check | one nix process per host (056a2741, #799) | yes |
| #785: scheduled-gate's ruff E501 failed acer's deploy build, reverted in #786 | deploy | build `pkgsDir.scheduled-gate` | yes: pool-merge-check builds each changed `pkgs/<dir>` (#788) |
| #793 and #796 each added the VM's gh stub, so main's evaluation and every push failed | push hook on main | `nix flake show` on the merge with main right before the merge | no: pool-merge-check does not run it |
| 703d2e8a added the `legacyPackages` output kind (`pkgsDir`), which nixos-flake-check's list lacked, so it failed after every output evaluated (19:20 run, 550 s); the step's second red cause today, after the one #815 fixed. Its aarch64 `pkgsDir` also failed to evaluate (`llm-bench` is x86 only), unseen | scheduled gate (19:20, head 05c028bb) | the flake's output kinds against the step's list (`scripts/flake-output-kinds.json`), no host evaluated: `scripts/test-flake-output-kinds.py`, about 7 s | yes: pool-merge-check runs it for `flake.nix`, `flake-modules/` and the list; the step now evaluates every `pkgsDir` drvPath (about 12 s) |
| Two slots' heavy evaluations shared acer's 7G slice: the push hook's `nix flake show` took the light lock, pool-merge-check's host evaluation the heavy one, so neither waited, and the kernel killed one twice on 25 Nov (#827) | slot memory kill (ExecPoolSlotMemoryKills) | pool-merge-check's evaluations take the light lock after the heavy one; `scripts/test-pool-merge-check.py` asserts both locks in that order (about 1 s) | yes (this branch) |
| `scripts/test-guest-records.py` fails on main: `local-lane` is in metrics/records.json's guest kinds but not in default.nix's `records.kinds`, so a slot's local-lane records are not shipped | this branch's run | the test itself, about 3 s, for `scripts/` and `modules/workers/`; pool-merge-check maps no script test to those paths | no |
| #777: every pane turn on acer failed with a herdr parse error, reverted in #778 | live slot | one session turn through a pane on a slot before the merge | no |

### First cuts (this branch)

- `just pool-merge-check` chooses its checks from the changed paths (`scripts/pool_merge_check.py`). docs/ and
  top-level `*.md`: nothing. Rule YAML: the five rule checks and grafana-dashboards (it reads the names each rule selects), no host. Dashboards: the two dashboard checks and black-pi's evaluation, which asserts each panel's datasource.
  `pkgs/exec-pool/`: its build plus acer's and msi's evaluation, and for a migration also its numbering. flake.lock:
  every host plus the private-input test. Any other path: every host, as before, plus each changed package's build.
  It prints each check it ran with its seconds and each host it skipped. It writes one gate-step record per check
  (gate=pool-merge-check, step=pool-merge-<kind>, result=pass|fail|skipped), so the minutes and run counts above can
  be read back from Loki. It writes no gate record: the platform gate pass rate stays the full gate's.
- The scheduled full gate runs twice a day (03:20, 15:20), down from four times. In the window its 2 reds each had one
  cause and stayed red on every run until a fix merged, so more runs did not find more. Each run holds acer's heavy
  lock for about 38 min. What covers the gap: the push hook's fast set on every push, pool-merge-check on every pull
  request, and the escape checks above. ScheduledGateOverdue moves from 14 h to 26 h, so one missed run does not page (at 12 h apart a missed run means a 24 h gap). No check was deleted.
- Rule for every session: a reply states the minutes of each check it ran and what any failure caught. An escape gets
  a row in the table above and a narrow check, not a longer gate.

Open: a slot's records go to its home's spool (PLATFORM_RECORD_SHIPPER=host); none was found there after the session moved to another slot, so confirm on acer after the deploy that pool-merge-check records reach Loki (`gate="pool-merge-check"`),
then fill the unknown minutes from 7 days of records. Evaluate `execution-pool-vm` for `modules/workers/` changes.
Run `nix flake show` on the merge in pool-merge-check.

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
| [#653](https://github.com/sammasak/nixos-config/issues/653), slice 4 only | a GitHub App and its key, for per-task tokens |
| [#645](https://github.com/sammasak/nixos-config/issues/645) | boot the gaming entry on asus once, at the machine and the TV |
| [#601](https://github.com/sammasak/nixos-config/issues/601), PR #616 | a physical reboot of black-pi for the kernel fix |
| [#474](https://github.com/sammasak/nixos-config/issues/474) | naked-pi: the step named on the issue, before its next deploy |
| [#620](https://github.com/sammasak/nixos-config/issues/620), msi | Pi in msi slots: msi as a recipient of `claude/*.yaml` (the gateway key) and in the `gateway-api` listener's `from` |

## Hosts and slots

Placement order: acer, then msi, asus last (it carries ollama, Paddock and the GPU).

| Host | Slots | Note |
|------|-------|------|
| acer-swift | `pool1` to `pool3` | Shunt on for `pool1`, a 300K compaction window for `pool2`; offers claude and pi, and codex while the owner's ChatGPT login exists |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30 |
| asus-b460m | none | ollama (one resident model, 130 W cap), agent `paddock`; off 21:00 to 08:30 |

No slot holds a GitHub key: slots push through acer's GitHub sidecar and private clones go through the proxy.
Gaming entries on asus and msi are merged and booted on neither host yet; the owner accepted them untested (#645).
