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
| 1 | Main is green ([#624](https://github.com/sammasak/nixos-config/issues/624) tail) | the scheduled gate on main passes, so a batch of merges is known good | `homelab_scheduled_gate_red` = 1 after the 19:20 run (head `05c028bbad89`, step `nixos-flake-check`): `legacyPackages` was a flake output kind the step lacked. PR #828 (merged 25 Nov 19:18 UTC) teaches the step the kind and guards output kinds at merge, no host moves; the dashboards red was fixed earlier by #814. The next scheduled run, 26 Nov 03:20, reads it | `ScheduledGateRed`, `RetroDueStepFailsRepeat` | the 03:20 scheduled run on main |
| 2 | Pi runs in a slot ([#620](https://github.com/sammasak/nixos-config/issues/620), closed) | `exec-pool submit --agent pi` completes a real two-line task | met on 25 Nov: three real tasks from lenovo (herman-75, llm-gateway-95a, llm-gateway-95b) on `homelab/local`, each passed the lane gate on attempt 1 in about 3 minutes, merged as herman#86, llm-gateway#106 and #107 | `nixos:workers-eval-test`; the lane's own record | the lane's next run |
| 3 | A tool-capable local model on asus ([#494](https://github.com/sammasak/nixos-config/issues/494), closed) | the gateway routes Pi's tool loop to a model on the asus GPU | met on 25 Nov: a tool call on model `local` passed at 19:44 and the gateway counted 114 requests ok on `asus-paddock` over the three lane tasks; Ollama's `qwen3.5:4b` stays the fallback while Paddock is stopped | the gateway's provider health rule; `tool_capable = false` in `llm-gateway-asus.toml` if tool calls break | `checks.llm-gateway-asus` |
| 4 | Work-done ledger ([#806](https://github.com/sammasak/nixos-config/issues/806)) | the dashboard shows merged changes and cost per merged change by agent and model, and the local share | 25 Nov (UTC, by merge time, read 20:15 from Loki's exec-pool-session-report lines; #814 live on acer and black-pi): 44 merged: Claude 41 (27 `unknown` model, logged before #814; 14 `default`), Pi on `homelab/local` 3 (herman#86, llm-gateway#106, #107; one commit each, the task's own); 41 priced, 50.43 USD, mean 1.23 USD, median 1.05 USD per merged change; turns 142, 134 with a reported cost, 8 without (the 3 Pi tasks report none: unpriced, not free); local share 3 of 44 (6.8 %; 3 of 62 over 7 d). Read wrong: the table's day was its 24 h window's end (25 Nov showed as 26 Nov), now labelled `24 h to`; the report's first run logged 18 changes merged on 24 Nov as 25 Nov (a one-time backlog). This item's PR records the commit a run pushed (`results.head`, migration 27), gives `exec-pool sessions` `pr.head` and `rescued` (merged at another commit than the task pushed), and adds a `rescued` column and a 7 d local share stat; needs a deploy of acer-swift (queue, runner) and black-pi (dashboard), msi's runner after acer | `PoolCostPerMergedChangeHigh` (3 d mean above 8 USD, at least 10 merged) | exec-pool unit test in `just pool-merge-check`; one look at the table and the share after deploy. Follow-ups: a session keeps its last pushed head, but a turn on a runner from before 27 (msi until its deploy) leaves it stale, so a session that pushed there can read `rescued` true: deploy msi soon after acer; the 3 Pi tasks report no cost (the gateway knows the tokens) |
| 5 | Local-model lane ([#807](https://github.com/sammasak/nixos-config/issues/807)) | small real tasks from any repository are finished by Pi on a local model and merged | local share 3 of 3 on 25 Nov (herman-75, llm-gateway-95a, 95b; attempt 1 each, about 3 min), but the coordinator opened and merged the PRs by hand and the tasks sat at `needs_review`. This item's PR: a pass opens the PR of `pool/<task>` and merges it (merge commit, `pr=` in the record), each gated task is cancelled (migration 26 lets `cancel` settle `needs_review`, needs a deploy of acer-swift), a fail leaves the branch and prints why, and with no tool-capable tier 3 model ready at acer's `/status` the run exits 3 with one `result=skipped failed=no-local-model` record (black-pi's panel leaves skips out of the share). Owed: pool task `cli-bcbb76381cbb84e3` (merged as llm-gateway#107) still sits at `needs_review` and keeps `ExecPoolNeedsReview` firing; after acer-swift's deploy, from lenovo, `exec-pool cancel cli-bcbb76381cbb84e3` settles it (the lane submitted it; before the deploy it answers `needs_review`), or now, on acer as root, `exec-pool-queue resolve --attempt <its attempt> --epoch <its epoch> --to succeeded` (`exec-pool status cli-bcbb76381cbb84e3` gives both; a real-terminal sudo) | `LocalLaneRescueHigh` (share under 30 percent over 7 d, at least 10 tasks), not written yet | `nixos:local-lane-test` (about 15 s), then the commands below when asus is up |
| 6 | Paddock serves over HTTP ([#508](https://github.com/sammasak/nixos-config/issues/508), closed) | the 35B MoE model answers Pi's tool loop on asus through the gateway | met on 25 Nov: `paddock.service` on asus (Nix built, pinned Qwen3.6 35B) answers through the gateway, 114 requests ok on `asus-paddock` for the lane's three tasks | the gateway's health probe on `/healthz` (stopped or off: `local` falls to Ollama's `qwen3.5:4b`) | `checks.llm-gateway-asus`, `monitoring-rules-tests` |
| 7 | A slot changes only its own branch ([#653](https://github.com/sammasak/nixos-config/issues/653)) | a task cannot push or open a pull request outside `pool/<task id>` | push filter on for acer and msi (PR #805); `privateUsers` on for msi's 4 slots, and with this item's PR for acer's 3 (7 of 7 once acer-swift is deployed); refused pushes per day: `sum by (node) (increase(exec_pool_push_filter_pushes_total{result="refused"}[1d]))`, read once acer-swift and msi-ms7758 are deployed. Open: a pull request's head is not held to the task's branch (a body-reading gate), and slice 4 (GitHub App, needs-owner) | `ExecPoolPushesRefused` (3 refusals from one slot in an hour, not one); `execution-pool-vm` boots slots with `privateUsers`; the filter fixture counts one refused push | `just pool-merge-check BRANCH`; one passed and one refused push on the host, its `refused` count up by one |
| 8 | Pool findings ([#646](https://github.com/sammasak/nixos-config/issues/646)) | a session never sits unseen and a deploy does not block claims | `exec_pool_sessions_stalled` = 0; `turn_error` 12 and `host_draining` 11 transitions in total; slots quarantined 0 | the nine `ExecPool*` rules | `just pool-merge-check BRANCH`; the finding seen gone in its signal after deploy |
| 9 | Alerts that name what to do ([#624](https://github.com/sammasak/nixos-config/issues/624)) | every page names its command; an alert starts its own investigation | PR #823 (merged 25 Nov 18:44 UTC) is deployed: ScheduledGateRed, RetroDueStepFailsRepeat and ExecPoolSlotMemoryKills are candidates, and three investigations ran and wrote their reports on their `Alert: <name>` issues. `homelab_alert_investigations_total` at 25 Nov 22:44 UTC: ScheduledGateRed started 3, reported 1, failed 2 (both `session_failed`: cancelled seconds after a finished turn, reports intact); RetroDueStepFailsRepeat and ExecPoolSlotMemoryKills started 1, reported 1. The fix (branch `pool/cli-0f2b3233fe5af769`, lenovo deploy) counts a session cancelled after its turn ended as reported and posts its report, starts no second investigation of a name within 6 h of its report, and points the prompt at the slot's read-only routes (docs/alert-runbooks.md#reading-an-alert-from-a-slot) and at a fix already on main. Open: after the deploy, the next ScheduledGateRed report names its cause or its fix PR, and failed stays 2; read the next 14-day firing list for the next names to switch on | the annotation contract check; `AlertInvestigationFailed`, `AlertInvestigationsStale` | the rule fixture tests |
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
Ran and merged the same evening: `herman-75` (herman#86), `llm-gateway-95a` (#106), `llm-gateway-95b` (#107).

#### Next lane tasks (run when asus is up)

On lenovo (it has `exec-pool`, `claude` for the review and a `gh` login), one at a time, after this item's PR merges
and acer-swift is deployed (migration 26):

```bash
cd ~/nixos-config && git pull -q --ff-only
lane() { python3 scripts/local-lane.py run --repo "https://github.com/sammasak/$1.git" \
  --prepared "$(git ls-remote "https://github.com/sammasak/$1.git" refs/heads/main | cut -f1)" \
  --check-script "scripts/lane-checks/$2.py" "${@:3}"; }

lane herman herman-57 --scope tools/perf-metrics/gate-tests.sh --lint none --task 'herman#57: in tools/perf-metrics/gate-tests.sh add an executed control for no_source_paths from tools/web/web.sh. Just before the line total=$((passed + failed)) near the end, extract the no_source_paths function body from "$WEBSH" with awk, the way the web-dist arm is extracted near line 790. Make a lab dir with apps/herman-web/dist/herman-web-1_bg.wasm, and run the function in a subshell with root set to that dir. Write the wasm with the text /registry/src/ in it, run the function, and add check "no_source_paths refuses a wasm holding /registry/src/" 1 "$RC". Then write it with clean text, run again, and add check "no_source_paths passes a clean wasm" 0 "$RC". Add a one-line comment above the block saying a no-op edit to no_source_paths must turn the gate red. Raise EXPECTED_CHECKS=408 at the top by the number of checks you add.'

lane herman herman-76 --scope apps/herman/src/data.rs --lint none --task 'herman#76: in apps/herman/src/data.rs, in the tests module, make fn temp_url remove the test databases that earlier runs left in the temp dir. At the start of temp_url, after building path, read std::env::temp_dir() with std::fs::read_dir. For each file whose name starts with "herman-desktop-", take the pid between that prefix and the next "-". If that pid is not std::process::id() and /proc/<pid> does not exist, remove the file and ignore errors. This also clears the -wal, -shm and -journal siblings. Leave the rest of temp_url and all its callers unchanged. Add a one-line comment saying why: every rust:ci run left about 40 databases in /tmp, a shared tmpfs.'

lane factum factum-61 --scope crates/factum-worker/src/plan/driver.rs --scope crates/factum-worker/src/plan_cli.rs \
  --scope crates/factum-worker/src/plan/report.rs --lint none --task 'factum#61: print the Widest hint also when selection ends at selection_attempts_exhausted. In crates/factum-worker/src/plan/driver.rs add the field widest: Option<Widest> to PlanStop::SelectionAttemptsExhausted, with a doc comment like the one on SelectionTooWide. Where the select stage returns that stop, set widest: candidates.widest().filter(|w| w.targets() > 6).cloned(). In crates/factum-worker/src/plan_cli.rs extend the if let that prints eprintln!("factum-worker: {widest}") for PlanStop::SelectionTooWide { widest: Some(widest), .. } with a second pattern, | PlanStop::SelectionAttemptsExhausted { widest: Some(widest), .. }. In crates/factum-worker/src/plan/report.rs change the arm SelectionAttemptsExhausted { last } to { last, .. }. Do not change the report, wire, modes or the exit codes.'
```

`nixos-config-bench-qwen` lints with `devenv shell -- just lint-comments`, which lenovo's stale devenv gate cannot run
(pool finding 3), so it runs on acer as lukas in `~/nixos-config`, with the same `lane` function and the gateway's
status on loopback: `LOCAL_LANE_STATUS=http://127.0.0.1:9091/status lane nixos-config nixos-config-bench-qwen` plus
its `--scope`, `--lint` and `--task` from the PR #816 comment. With asus off every command exits 3 with "no local model
up" and submits nothing. herman-57's check reads a `.sh` file in herman; factum-61 compiles only in factum's gate, so
its lane review is the first reader of the code.

Follow-ups for the lane (not in this PR): three more checks (the open issues in the five repos are too big, done
already or investigations; pi-harness issues answer 403 over REST); `LocalLaneRescueHigh`; a `pool/*` push that skips
llm-gateway's `sdlc:done` and herman's `rust:ci` pre-push gates, so Pi's own push cannot fail at `push`; a `land`
failure retried by hand today (the record says `failed=land`).

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
4. ~~Re-measure lenovo's user slice now that the named workers are pool slots~~: read 25 Nov 20:20 from Prometheus
   and Loki: 14 OOM kills in `user.slice` on 23 Nov (Loki shows 11: 8 under Herdr's workers, codex, nix and devenv, a nix run and two Firefox tabs), none
   since 23 Nov 15:23; over the last 2 days the whole host's anon plus shmem peaked at 6.7 GiB (11.2 GiB in the 8
   days before), used memory at 8.0 GiB, swap free never under 6.2 of 7.7 GiB, memory pressure 0.1 %. The user
   slice is under that 6.7 GiB, its cap 8032M is not clearly off: kept. No metric reads the slice itself (lenovo
   ships no user units to Loki and exports no cgroup memory); follow-up if it is to be cut.
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
   `exec_pool_memory_kills_total` flat on acer over a day of merges. Fixed on pool/cli-406f00699b51d8ad (live after
   acer's deploy): in a slot `nix eval`, `path-info`, `derivation` and `flake show|metadata|info` run under the light
   lock, and `nix build` of flake attributes evaluates each `.drvPath` under it and builds `drv^*` outside; `devenv`
   runs its eval, info, search and direnv-export under it, and before shell, tasks, test, up, processes and build
   warms its eval cache with `shell -- true` under it (85 s and 1.2 GiB cold, 1 s warm), so no compile and no task
   that may take heavy holds light; pool-merge-check and the push evaluation set `WORK_LOCKS_HELD=1` so their nix
   skips it. Reading, 25 Nov 21:27Z, before that deploy: kills over 24 h pool1 5, pool2 1, pool3 2 (pool1's last
   about 21:17Z, after PR #830's merge), msi 0; `max_over_time(homelab_guest_memory_peak_bytes[1d])` pool1 5.3 GiB,
   pool2 1.8, pool3 5.4. Signal: the counter flat on acer for a day after the deploy. Follow-ups, still unlocked:
   `nix flake check`, `nix build` with another option or a non-flake installable, `nix-build`, `nix-instantiate`, a
   global option before the subcommand, and a devenv evaluation a warm `shell` does not cache (another `-O` option);
   acer's 7G stays (15 GiB, ollama 4G).
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
| Two slots' heavy evaluations shared acer's 7G slice: the push hook's `nix flake show` took the light lock, pool-merge-check's host evaluation the heavy one, so neither waited, and the kernel killed one twice on 25 Nov (#827) | slot memory kill (ExecPoolSlotMemoryKills) | pool-merge-check's evaluations take the light lock after the heavy one; `scripts/test-pool-merge-check.py` asserts both locks in that order (about 1 s); this branch's `just pool-merge-check` ran 12 checks in 6.0 min on acer (grafana-dashboards 3.4, six host evaluations 2.0) | yes (this branch) |
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
| acer-swift | `pool1` to `pool4` | Shunt on for `pool1`, a 300K compaction window for `pool2`; `pool4` light (1G reserve, CPUWeight 100 against 200, CPUQuota 200%); offers claude and pi, and codex while the owner's ChatGPT login exists |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30 |
| asus-b460m | none | ollama (one resident model, 130 W cap), agent `paddock`; off 21:00 to 08:30 |

Heat, the extra slot's price (owner, 25 Nov 23:50). Before, 25 Nov 23:50 with three acer slots busy: acer 8 cores, load
5.0, 11.3 GiB available of 15.6, environments.slice 2.5 of 7 GiB, package 66 C now and 94 C peak in 6 h,
node_cpu_core_throttles_total up about 888,000 in 6 h, no fan sensor; lenovo 16 cores, load 0.3, 10.9 GiB available
of 15.7, user.slice 4.3 of 8.4 GiB, 49 C now and 100 C peak in 6 h, fans 0 rpm idle (its 65535 peak is the sensor's
error value). After, 24 h past the pool4 deploy: acer's throttle increase over 24 h and peak temperature with four
slots against the 24 h before that deploy with three (the Hosts dashboard's heat row;
`sum(increase(node_cpu_core_throttles_total{node="acer-swift"}[24h]))` and `max_over_time(homelab:node:hwmon_temp_max_celsius{node="acer-swift"}[24h])`).
If acer's throttling rises by more than half, drop pool4 again (`slots = 3`, `light.slots = 0`). lenovo's first slot is
not in this layout yet.

No slot holds a GitHub key: slots push through acer's GitHub sidecar and private clones go through the proxy.
Gaming entries on asus and msi are merged and booted on neither host yet; the owner accepted them untested (#645).
