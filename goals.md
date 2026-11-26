# Goals: one priority queue

The direction this queue serves: [vision.md](vision.md). Realigned on 25 Nov 2026, 22:30 UTC, against vision.md and
every open issue and pull request in the seven repositories. What shipped is in git history and the closed issues.

## How we work (owner, 23 to 25 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break (DNS, data at risk) jumps the queue.
- Night is for shipping: "focus on shipping and not so much on small regressions during night". A red gate step is
  one queued item, not an urgent break.
- No dedicated benchmarks. Ship behind a switch scoped to one host, slot or model and compare on the running system.
- Every queued item names the outcome a user sees, one metric read on the running system, a regression alert or
  guard, and a narrow quality gate of minutes. The scheduled full gate on main covers the batch.
- "40 min build time is crazy": a gate that long is a defect to fix (item 1), not a cost to accept.
- "anytime a worker builds something it should be put into the cache".
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send`), never to Herdr panes. The one
  exception is the agent `paddock` on asus, which needs the GPU.
- Capacity follows the hosts that are up: msi and asus are off 21:00 to 08:30 and are never woken; acer and lenovo
  keep working the queue at night.
- Prefer upstream nixpkgs modules and built-in features over home-made services.
- Owner gates: only what no agent can do (physical access, a real-terminal sudo, money, an account-level
  credential, an approval the owner reserved). Those carry `needs-owner` and are listed at the end.

## What "more work done" means

Tracked by [#806](https://github.com/sammasak/nixos-config/issues/806); PR #832 adds the pushed head, `rescued` and a
7 d local share, live after deploys of acer-swift and black-pi.

| Measure | Last reading |
|---|---|
| Merged pool changes per day, by agent and model | 25 Nov: 44 merged, Claude 41, Pi on `homelab/local` 3 (read 20:15 UTC) |
| Cost per merged pool change | 25 Nov: mean 1.23 USD, median 1.05 USD over 41 priced (the 3 Pi tasks report no cost) |
| Local share: local-model tasks merged with no hosted model writing the code | 3 of 44 on 25 Nov; Loki holds 3 `local-lane` records in 36 h, all `result=passed` |
| Pull requests merged, all repositories, 7 d (`shipping_prs_merged`) | 254 (25 Nov 12:10 UTC) |
| Lead time, dispatch to merge | p50 0.47 h, p90 4.6 h (25 Nov 12:10 UTC) |

## Queue, in pick-up order

Readings at 25 Nov 22:15 UTC from black-pi's Prometheus and Loki (a slot reads them at `$PROMETHEUS_URL` and
`$LOKI_ADDR`), unless the cell says otherwise.

| # | Item | Serves (vision.md) | Metric, reading | Narrow check |
|---|------|--------------------|-----------------|--------------|
| 1 | Gate speed, and every worker build lands in the cache ([#835](https://github.com/sammasak/nixos-config/issues/835)); carries the red gate (#828 is the fix) | "No dedicated benchmarks, no long test rituals" | 7 d of gate-step records (measured 25 Nov): flake check mean 13.7 min, worst 28.8; gate probe 3.9; seventh-host test 3.2; workers-eval test 2.0; inside the flake check evaluation 8 to 18 min against building 3 to 13 min per run, 100 to 330 compiled and 20 to 100 fetched; merge check host evaluation 47 s mean, 189 min in the week. `homelab_scheduled_gate_red` = 1, head `05c028bbad89`, step `nixos-flake-check`. Where the time goes and the store upload (#839): Check tuning | the step's own record on the 26 Nov 03:20 scheduled run |
| 2 | Alert investigations end with a cause ([#624](https://github.com/sammasak/nixos-config/issues/624); [#825](https://github.com/sammasak/nixos-config/issues/825), [#826](https://github.com/sammasak/nixos-config/issues/826), [#827](https://github.com/sammasak/nixos-config/issues/827)) | "Alerts are few and each one says what to do" | `AlertInvestigationFailed` firing. 24 h outcomes: ScheduledGateRed 2 failed (both sessions `cancelled`), 1 reported; RetroDueStepFailsRepeat 1 reported, ExecPoolSlotMemoryKills 1 reported, both without a cause ("the cause is unproven"). PR #840 (lenovo deploy) counts a session cancelled after its finished turn as reported, starts no second investigation of a name within 6 h of its report, and points the prompt at the slot's read-only routes; after the deploy failed stays 2 | the rule fixture tests; the next ScheduledGateRed report names its cause or its fix PR |
| 3 | Internal and outside service names ([#836](https://github.com/sammasak/nixos-config/issues/836), folds in [#14](https://github.com/sammasak/nixos-config/issues/14)): "we need to have internal dns names for services inside the cluster and outside; authentik is needed for real outside traffic but on our cluster it should not" | "DNS stays up"; "Upstream modules before home-made services" | services with an internal name answering without an Authentik redirect: unread (no series yet) | `adguard-dns-test`, one curl per internal name from the LAN |
| 4 | Check minutes from records ([#837](https://github.com/sammasak/nixos-config/issues/837)) | "Every change ships ... with a comparable metric" | rows in Check tuning still unknown: most. pool-merge-check records do reach Loki: 369 in 24 h, 224 host evaluations at a mean of 52 s (193 min) | the script's fixture test, seconds |
| 5 | Top open pool finding: slot memory kills ([#827](https://github.com/sammasak/nixos-config/issues/827), epic [#646](https://github.com/sammasak/nixos-config/issues/646)) | "Agents run in disposable sandboxes" that finish their work | `increase(exec_pool_memory_kills_total[24h])`: acer pool1 5, pool2 1, pool3 2; msi 0. #830 and #833 put a slot's evaluations under the light lock, live after acer-swift's deploy; signal: the counter flat on acer for a day after it | `just pool-merge-check BRANCH` |
| 6 | The biggest MoE on asus ([#838](https://github.com/sammasak/nixos-config/issues/838); paddock branch `asus/biggest-moe`, Qwen3.5 122B then 397B): "lets test what the biggest MoE model we can run" | "a large model can run on modest hardware" | largest model answering a tool call through the gateway, and its tokens per second: unread. The branch's last commit (25 Nov 19:49) needs the GPU for the 122B serve; asus is up Mon to Fri 08:30 to 21:00 | one tool call on model `local` through the gateway |
| 7 | skills [#170](https://github.com/sammasak/skills/issues/170): independent review of skills PR 169 (Shunt routing lessons) | "Only safety, or \"does not fix the problem\", blocks a change"; "The owner decides direction" | review posted: no (0 comments). PR 169 stays an unmerged draft until the owner approves (needs-owner) | the review comment on #170 |
| 8 | validate-bash fails open ([skills#107](https://github.com/sammasak/skills/issues/107)), moved up by anti-starvation | "secrets are never printed or committed, history is never force-pushed" | guards that fail open on unparsable hook input: unread; the issue names a NUL plus trailing JSON bypass | the hook's own test with that input |
| 9 | Local-model lane and the ledger ([#807](https://github.com/sammasak/nixos-config/issues/807), [#806](https://github.com/sammasak/nixos-config/issues/806), epic [#491](https://github.com/sammasak/nixos-config/issues/491)) | "the gateway routes between local and hosted models" | 3 passed lane tasks in 36 h (herman#86, llm-gateway#106, #107, attempt 1 each); #831 lets the lane open and merge its own PRs, live after acer-swift's deploy. Next tasks below, when asus is up | `nixos:local-lane-test` (about 15 s); the lane's own record |
| 10 | Live comparisons: Shunt and the 300K window ([#625](https://github.com/sammasak/nixos-config/issues/625), [#626](https://github.com/sammasak/nixos-config/issues/626)) | "Every change ships behind a switch ... judged on the running system" | 25 Nov 17:00 UTC: pool3 default 13 turns, 0.19 USD a turn; pool2 300K 12 turns, 0.15 USD; pool1 Shunt 8 turns, 0.89 USD, Shunt acted on none. Too thin: decide the window after 26 Nov 10:10 UTC, Shunt by 2 Dec | none to run: read and decide |

Anti-starvation: [#14](https://github.com/sammasak/nixos-config/issues/14) has waited longest (opened Oct 2025) and
moves into item 3. Next is skills#107 (13 Nov, 12 days), moved from Later to item 8. #625 (22 Nov) waits on its
read date, not on a slot.

Pool cost: `increase()` over `exec_pool_session_cost_usd_total` over-reads (float8 sums read as resets); read cost
from `exec-pool sessions` until the numeric sum (#814) is confirmed live on acer.

### Quality gate for a local-model task

All machine-checked, under 5 minutes, and it never takes the model's word:

1. A check prepared by a hosted agent fails on the base and passes on the head, run by the gate.
2. The check file is byte-identical to the prepared one.
3. The diff touches only the files in scope and at most 60 changed lines.
4. The repository's fast lints pass.
5. One cheap hosted review that may only say "unsafe" or "does not fix the problem".

Fail: one retry with the check's output. Second fail: a hosted agent finishes it and the task counts as rescued.
A model keeps the lane while its local share holds 50 percent or more after 20 tasks. `scripts/local-lane.py`
runs it; llm-gateway's and herman's pre-push gates can still refuse Pi's own push (a `pool/*` skip is the owner's call).

#### Next lane tasks (run when asus is up)

On lenovo (it has `exec-pool`, `claude` for the review and a `gh` login), one at a time, after acer-swift's deploy:

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

`nixos-config-bench-qwen` runs on acer as lukas (lenovo cannot run its lint, pool finding 2) with
`LOCAL_LANE_STATUS=http://127.0.0.1:9091/status` and the `--scope`, `--lint` and `--task` from the PR #816 comment.
With asus off every command exits 3 with "no local model up" and submits nothing.

## Open pool findings (item 5 and epic #646, in pick-up order)

1. Slot memory kills: the slots share one `environments.slice` limit (acer 7G of 15 GiB, ollama 4G). #830 and #833
   put a slot's evaluations under the light lock and builds outside it, live after acer-swift's deploy. The push
   hook's gate probe (`nix build --expr` with devenv's own nix) took no lock and no slot wrapper saw it: #843 has it
   take light itself (live on merge), and in a slot `nix build --expr`, `nix --option k v <sub>` and
   `nix-instantiate` evaluate under light, building the default outputs (live after acer's deploy). Signal:
   `exec_pool_memory_kills_total` flat on acer for a day after it. Still unlocked: `nix flake check`, `nix build`
   with another option, `--file` or `--expr` with an attribute, `nix-build`, the evaluated `.drv` unrooted until its
   build, and a devenv evaluation a warm `shell` does not cache.
   A goals.md-only push ran `scripts/test-pool-merge-check.py` (it named goals.md), which needs the gate probe; the
   probe was killed 5 times in acer pool2 on 25 Nov. The test now uses placeholder doc names (this PR).
2. lenovo cannot push nixos-config (stale devenv gate); its root rebuild trigger needs a GitHub SSH key for root.
3. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.
4. A pull request's head is not held to the task's branch ([#653](https://github.com/sammasak/nixos-config/issues/653)).
   The push filter is live on both hosts: 1 d of `exec_pool_push_filter_pushes_total`, acer 17 passed, msi 3, 0 refused.
5. Turn errors per arm: `exec_pool_session_turn_errors_total{host,variant,shunt,agent}` (turn_error, turn_timeout,
   turn_memory_kill) and `host_variant:exec_pool_session_turn_errors:increase1d`, live after acer-swift's deploy.
   Follow-up: a row for it in the Agent harnesses comparison table.

## Check tuning

Owner, 25 Nov: "keep count of how we can fine tune testing so that we can have some small and fast checks applied and
only run long gates even less often". Per-step seconds sit in Loki's `{job="platform",kind="gate-step"}` records
(`gate="nixos-qa"` or `gate="pool-merge-check"`); item 4 fills the unknowns from them. "Caught" means a fix commit or
pull request names the check as what failed.

The full gate runs only as the scheduled gate (acer, 03:20 and 15:20, when main moved) or `just full-gate`.
`just pool-merge-check` picks its checks from the changed paths (`scripts/pool_merge_check.py`; docs: nothing) and
writes one gate-step record per check.

| Check or step | Typical minutes | Real defects caught (commit or PR) | Depends on |
|---|---|---|---|
| Whole scheduled gate | 37.6 (24 Nov); "40 min build time is crazy" | 4 reds: `shunt-metrics-test` (#759), `execution-pool-vm` evaluation (#795), `grafana-dashboards` (#814), `legacyPackages` output kind (#828) | everything |
| lint-comments, lint-shell, deploy-rs-pins | seconds (3 to 4 s in records) | lint-comments 9d7cec2a (#800); shellcheck d947c2a2 (#795) | `.nix`, `.sh`, `.py`; `scripts/*.sh`; devenv and flake locks |
| fmt-check | 4 s in records | 747a1f71 (#684) | every `.nix` |
| secrets-verify | seconds | none traced | `secrets/` |
| nixos-push-eval (`nix flake show`) | about 1.5 (90 s, 3.9 GiB, acer) | 24cb9892 (#797) | every flake output's attribute set |
| gate probe | 3.9 mean (7 d) | none traced | every host |
| nixos-flake-check | 13.7 mean, 28.8 worst (7 d) | `execution-pool-vm` (#795); ruff E501 (#787); exec-pool clippy and rustfmt; `legacyPackages` (#828) | every check and every x86 host |
| workers-eval-test | 2.0 mean (7 d) | 0b90b42d (#781), f4fac5f5 (#736) | gate probe, `modules/workers/` |
| seventh-host-test | 3.2 mean (7 d) | none traced | hosts.nix, fleet.nix, every host |
| shunt-metrics-test | unknown | df0f5007 (#759) | probe, `scripts/shunt-metrics.py` |
| deploy-recipes-test | about 0.05 | fails on a `github:` private input since #803 | Justfile, flake.lock |
| The other tests in `tests` (devenv.nix) | unknown | none traced | most read the gate probe |
| pool-merge-check: host evaluation | 47 s mean per host, 189 min in 7 d; 52 s over 224 in the last 24 h | lenovo's sam.memory budget (#794, #799) | the host's modules and `hosts/<dir>/` |
| pool-merge-check: package build | 195 s mean over 22 builds in 24 h | c15a3024 (#795) | `pkgs/<dir>/` |

### Where the time goes, and what a cache can save (Loki, read from a slot on 25 Nov)

Two scheduled runs: 24 Nov 15:20 (head 191e1d1, 2232 s, every step, red only on `shunt-metrics-test`) and
26 Nov 03:20 (head d824cc76, 5407 s, red at `workers-eval-test`, so the 40 steps after it did not run). Gate-step
records; seconds are 24 Nov / 26 Nov:

| Step | Seconds | Of which evaluation | Of which building | Derivations compiled / substituted; checks built / present / deferred |
|---|---|---|---|---|
| nixos-flake-check | 1373 / 3874 | 531 / 1102 (one `nix eval` per output, summed) | 500 / 2003; the rest is `nix flake show`, the dry-runs and the per-output processes | 320 / 0; 15 / 25 / 2 on 24 Nov. 419 / 38; 20 / 22 / 2 on 26 Nov |
| nixos-gate-probe | 206 / 825 | all of it (every host once) | 0 | none |
| workers-eval-test | 263 / 627 (red) | all of it (its own host and guest evaluations) | 0 | none |
| seventh-host-test | 171 / not run | all of it (every host again, seeded) | 0 | none |
| The other steps | 208 / 79 (7 ran) | mostly | mostly none | none |

26 Nov ran 2.4 times slower step for step. acer runs at 60 % at night (sam.fleet quiet), and all three acer slots
evaluated beside it: each slot's push hook ran a `nix flake show` (188 to 530 s, light lock) while the gate held the
heavy one, and slot memory reached 4 to 5 GiB each. The gate waited 0 s for its lock, so the locks did not
serialise it against the slots. On 26 Nov, 38 derivations were substituted, against 0 on 24 Nov. The VM tests
dominate building: execution-pool-vm 702 s, grafana-dashboards 383 s, alert-fire-resolve 381 s.

The answer to "how much would a cache save": at most the 500 s of building, 22 % of the gate. Not one path was
substituted, because everything not built was already in acer's store. The 320 compiled derivations were the
deploy checks' systems (msi 132, acer 28, lenovo 15) and the VM tests, built for a head no host had built before.
What a deploy built on msi or asus is the part the upload below makes present on acer. Evaluation is about 1170 s, more
than half the gate: the probe, the flake check, workers-eval and seventh-host each evaluate the hosts on their own.

pool-merge-check, 51 runs on 24 and 25 Nov: median 369 s (6.2 min), mean 401 s, max 1452 s; host evaluation is
57 % of it, package builds 21 %, the named checks 22 %.

Owner, 25 Nov: "anytime a worker builds something it should be put into the cache". What already held: acer's slots
build through acer's daemon into the store its harmonia serves, and lenovo substitutes from acer. msi's and asus's
builds were served only while they were up, and no host asks them (a sleeping cache costs every lookup the connect
timeout). `modules/core/store-upload.nix` (this branch) closes that: a `post-build-hook` on msi and asus queues each
built output. A path unit and a 10 min retry timer hand the queue over ssh (the host key, a forced command) to acer,
which pulls the paths from the sender's harmonia, keeps them under gcroots, and roots its own builds the same way.
Retention is 14 days and 100 GiB of the closures they hold, oldest dropped first. Gauges: `store_upload_queue_paths`,
`store_upload_sent_paths_total`, `store_upload_last_success_timestamp_seconds` on the senders;
`store_upload_roots{host}`, `store_upload_roots_bytes{host}`, `store_upload_roots_closure_bytes` and
`store_upload_received_paths_total{host,result}` on acer.

Follow-ups, in order: (1) the scheduled gate alone on acer: a slot's evaluations wait while it holds the heavy lock,
or the gate moves out of the slots' hours; (2) one evaluation of every host shared
by the probe, the flake check and seventh-host (about 400 s); (3) the flake check's per-output `nix eval` processes
as one `nix-eval-jobs` run; (4) an alert on `store_upload_queue_paths` growing while acer is up; (5) acer's
max-jobs and cores (2 and 2) against the memory budget.

### Escapes still without a narrow check

| Escape | Smallest check that would catch it |
|---|---|
| #793 and #796 each added the VM's gh stub, so main's evaluation failed | `nix flake show` on the merge in pool-merge-check |
| `execution-pool-vm` failed to evaluate for a `modules/workers/` change | that check's drvPath evaluated for `modules/workers/` changes |
| `local-lane` is in metrics/records.json's guest kinds but not in `records.kinds` | `scripts/test-guest-records.py` (about 3 s) mapped to `scripts/` and `modules/workers/` |
| #777: every pane turn on acer failed with a herdr parse error | one session turn through a pane on a slot before the merge |
| Five red acer scheduled runs from 24 Nov 20:37Z wrote only the step record (`check` empty), so RetroDueStepFailsRepeat named no check (#826); #841 names each guard (`scripts/test-gate-steps.py`). Open: `for s in $(names packages)` ignores a failed listing, so the step passes short of those outputs | a failed listing fails the step, a case in `scripts/test-gate-steps.py` |

Rule for every session: a reply states the minutes of each check it ran and what any failure caught. An escape gets
a row above and a narrow check, not a longer gate.

## Later (not queued; one line each)

- [#653](https://github.com/sammasak/nixos-config/issues/653): a PR head held to the task's branch (pool finding 4); slice 4 is needs-owner.
- [#834](https://github.com/sammasak/nixos-config/issues/834), skills [#167](https://github.com/sammasak/skills/issues/167), [#168](https://github.com/sammasak/skills/issues/168): Shunt pilots for Codex and Pi, one-shot boilerplate, a local bulk-read backend; after item 10 decides Shunt.
- [#611](https://github.com/sammasak/nixos-config/issues/611): native OTLP requests above 1 MiB; fix #613 merged, relay rejections per day unread.
- [#600](https://github.com/sammasak/nixos-config/issues/600): the milestone items 1, 2 and 10 report to.
- skills [#128](https://github.com/sammasak/skills/issues/128) (one cheap review for small changes), [#104](https://github.com/sammasak/skills/issues/104) (orchestrated-review ships its own prompts).
- paddock PRs 1, 2 and 3 (drafts: Nix setup, SSD expert backing RFC, steps 2 to 4): untested on a GPU; feed item 6.
- llm-gateway [#69](https://github.com/sammasak/llm-gateway/issues/69): request id in a header, blocked.
- factum [#61](https://github.com/sammasak/factum/issues/61), herman [#57](https://github.com/sammasak/herman/issues/57), [#62](https://github.com/sammasak/herman/issues/62), [#76](https://github.com/sammasak/herman/issues/76): lane supply (item 9).
- herman is parked for the platform sprint: #1, #3, #7, #9, #10, #11, #14, #15, #21, #22, #25, #27, #29, #30 and #85.
- pi-harness: its issues answer 403 over REST, unread.

## Horizon (direction only, no work scheduled)

- The pool as a coding platform: any repository, guest users (vision.md).
- The app platform, epic [#557](https://github.com/sammasak/nixos-config/issues/557): next step is to register one
  real app. Apps in the registry today: 0.
- devenv-platform#156 to #166, workload orchestration research (`horizon`): vision.md names no container orchestrator.

## needs-owner (what no agent can do)

| Issue | What is needed |
|---|---|
| skills PR 169 (review in [skills#170](https://github.com/sammasak/skills/issues/170)) | the owner's approval to merge, after the independent review |
| [#653](https://github.com/sammasak/nixos-config/issues/653), slice 4 only | a GitHub App and its key, for per-task tokens |
| [#645](https://github.com/sammasak/nixos-config/issues/645) | boot the gaming entry on asus once, at the machine and the TV |
| [#601](https://github.com/sammasak/nixos-config/issues/601), PR #616 | a physical reboot of black-pi for the kernel fix |
| [#474](https://github.com/sammasak/nixos-config/issues/474) | naked-pi: the step named on the issue, before its next deploy |
| Pi in msi slots | msi as a recipient of `claude/*.yaml` (the gateway key) and in the `gateway-api` listener's `from` |

## Hosts and slots

Placement order: acer, then msi, asus last (it carries ollama, Paddock and the GPU). At night only acer and lenovo
take work.

| Host | Slots | Note |
|------|-------|------|
| acer-swift | `pool1` to `pool4` | Shunt on `pool1`, 300K compaction window on `pool2`; `pool4` light (1G reserve, CPUWeight 100 against 200, CPUQuota 200%), the slice raised from 7G to 9G (three slots filled 7G twice on 25 Nov, kills at 22:01 and 23:25); offers claude and pi, and codex on the owner's ChatGPT login; deploy owed for #831, #832, #833 |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30 |
| asus-b460m | none | ollama (one resident model, 130 W cap), `paddock.service` (Qwen3.6 35B, #817, #822), agent `paddock`; off 21:00 to 08:30 |

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
