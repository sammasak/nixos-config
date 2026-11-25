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
| 1 | Main is green ([#624](https://github.com/sammasak/nixos-config/issues/624) tail) | the scheduled gate on main passes, so a batch of merges is known good | `homelab_scheduled_gate_red` = 1 (step `nixos-flake-check`, head `24964ca3c669`, 17 failures of that step counted) | `ScheduledGateRed`, `RetroDueStepFailsRepeat` (both firing) | rerun the one red step on acer: `NIXOS_STEP=nixos-flake-check devenv tasks run nixos:step` |
| 2 | Pi runs in a slot ([#620](https://github.com/sammasak/nixos-config/issues/620)) | `exec-pool submit --agent pi` completes a real two-line task | `exec_pool_attempts{agent="pi",state="succeeded"}` = 0; 2 failed in 5 s on 25 Nov before any model was reached; fix in #811 (`PI_CODING_AGENT_DIR`; by hand in acer `pool3`: exit 0 on `homelab/auto`), needs a deploy of acer-swift | `nixos:workers-eval-test` checks that the step's env names the dir holding Pi's `models.json`; the canary as a daily task once green | `just pool-merge-check BRANCH` (about 3 min), then the canary task on acer |
| 3 | A tool-capable local model on asus ([#494](https://github.com/sammasak/nixos-config/issues/494)) | the gateway routes Pi's tool loop to a model on the asus GPU | gateway requests served by asus, 7 d: 0 (no host enabled the provider; its gemma4 entry was not `tool_capable`); project pi: 308 requests, all hosted free models. This item's PR enables it on acer with `qwen3.5:4b` first in tier 3 (`local`, and `auto` once every cloud model is out), msi's llama3.1 text-only; owed, in this order: `ollama pull qwen3.5:4b` on asus (or `homelab.ollama.toolModel.enable` and a deploy of asus), then a deploy of acer-swift; deployed first, the first `local` tool call 404s and blocks the model for 6 h | the gateway's provider health rule; set `tool_capable = false` in `llm-gateway-asus.toml` if the canary fails | the #620 canary with `--model homelab/local` through the gateway; `checks.llm-gateway-asus` |
| 4 | Work-done ledger ([#806](https://github.com/sammasak/nixos-config/issues/806)) | the dashboard shows merged changes and cost per merged change by agent and model | the table above; cost reported for 114 of 143 turns; [#814](https://github.com/sammasak/nixos-config/pull/814) adds the model, one-shot tasks, the "Merged changes per day" table and the exact cost counter, needs a deploy of acer-swift (queue, migration 24) and black-pi (dashboard, Loki rule); `rescued` and local share still open (the runner must record the head it pushed); the same PR fixes `grafana-dashboards` on main (it missed `exec_pool_memory_kills_total`) | `PoolCostPerMergedChangeHigh` (3 d mean above 8 USD, at least 10 merged) | exec-pool unit test in `just pool-merge-check`; one look at the table after deploy |
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
| Whole scheduled gate | 37.6 (first run, 2256 s on acer, 24 Nov); the unit comment says 20 to 40 | at most 4 | 2 reds: `shunt-metrics-test` (a stale guest name after #748, fixed df0f5007 in #759), `execution-pool-vm` failing to evaluate (#795) | everything |
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
| A host evaluation in a slot was killed for memory three times | pool-merge-check | one nix process per host (056a2741, #799) | yes |
| #785: scheduled-gate's ruff E501 failed acer's deploy build, reverted in #786 | deploy | build `pkgsDir.scheduled-gate` | yes: pool-merge-check builds each changed `pkgs/<dir>` (#788) |
| #793 and #796 each added the VM's gh stub, so main's evaluation and every push failed | push hook on main | `nix flake show` on the merge with main right before the merge | no: pool-merge-check does not run it |
| #777: every pane turn on acer failed with a herdr parse error, reverted in #778 | live slot | one session turn through a pane on a slot before the merge | no |

### First cuts (this branch)

- `just pool-merge-check` chooses its checks from the changed paths (`scripts/pool_merge_check.py`). docs/ and
  top-level `*.md`: nothing. Rule YAML: the five rule checks, no host. Dashboards: the two dashboard checks and black-pi's evaluation, which asserts each panel's datasource.
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
