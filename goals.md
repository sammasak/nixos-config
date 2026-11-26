# Goals: one priority queue

The direction this queue serves: [vision.md](vision.md). Realigned on 26 Nov 2026, 11:10 UTC, against vision.md and
every open issue and pull request in the nine repositories (pi-harness answers 403 over REST, so its issues are
unread); the queue updated to the state of 26 Nov 18:00 UTC. What shipped is in git history and the closed issues.

## How we work (owner, 23 to 26 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break (DNS, data at risk) jumps the queue.
- Night is for shipping: "focus on shipping and not so much on small regressions during night". A red gate step is
  one queued item, not an urgent break.
- No dedicated benchmarks. Ship behind a switch scoped to one host, slot or model and compare on the running system.
- Every queued item names the outcome a user sees, one metric read on the running system, a regression alert or
  guard, and a narrow quality gate of minutes. The scheduled full gate on main covers the batch.
- "40 min build time is crazy": a gate that long is a defect to fix (item 4 and Check tuning's follow-ups), not a cost to accept.
- "anytime a worker builds something it should be put into the cache".
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send`), never to Herdr panes. The one
  exception is the agent `paddock` on asus, which needs the GPU.
- Review is sized by risk (skills#175): only credentials, the pool runner, firewall rules and listeners get the
  orchestrated review. The coordinator merges on an independent 9/10 review and a green narrow gate (skills#173).
- Capacity follows the hosts that are up: msi and asus are off 21:00 to 08:30 and are never woken; acer and lenovo
  keep working the queue at night.
- Prefer upstream nixpkgs modules and built-in features over home-made services.
- Owner gates: only what no agent can do (physical access, a real-terminal sudo, money, an account-level
  credential, an approval the owner reserved). Those carry `needs-owner` and are listed at the end.
- 26 Nov: pull requests ship on the session's narrow check on its own head, the in-session independent review and a
  textually clean merge; nobody re-runs a merge check on current main. The scheduled gate on acer, three runs a day,
  is the backstop, and a clash between two clean merges costs one fix-forward pull request.
- Paddock (26 Nov, #874): "Ensure that we track this work and that we harden and fix the implementation once we are happy with it and start using this for real in our setup. Once we have find the right model fit and run pi-agents to get real feedback and metrics we can then continue to harden it and eventually do a upstream contribution. Also since we are doing this we need to keep in mind that other contributions are going to the main thing and not to our fork so we need to keep our branches up to date. Also some of work might already be fit for upstream (nix? - what metrics do we need here before we are happy with upstreaming it?)"

## What "more work done" means

Tracked by [#806](https://github.com/sammasak/nixos-config/issues/806); the pushed head, `rescued` and a 7 d local
share (#832) are live with acer-swift's and black-pi's deploys. Readings below are from 25 Nov (GitHub search
answers nothing through the pool's proxy, so 26 Nov is not read here).

| Measure | Last reading |
|---|---|
| Merged pool changes per day, by agent and model | 25 Nov: 44 merged, Claude 41, Pi on `homelab/local` 3 (read 20:15 UTC) |
| Cost per merged pool change | 25 Nov: mean 1.23 USD, median 1.05 USD over 41 priced (the 3 Pi tasks report no cost) |
| Local share: local-model tasks merged with no hosted model writing the code | 3 of 44 on 25 Nov; Loki holds 3 `local-lane` records in 36 h, all `result=passed` |
| Pull requests merged, all repositories, 7 d (`shipping_prs_merged`) | 254 (25 Nov 12:10 UTC) |
| Lead time, dispatch to merge | p50 0.47 h, p90 4.6 h (25 Nov 12:10 UTC) |

## Queue, in pick-up order

State of 26 Nov 18:00 UTC, in the coordinator's order. Readings are from black-pi's Prometheus and Loki (a slot
reads them at `$PROMETHEUS_URL` and `$LOKI_ADDR`) between 10:00 and 11:00 UTC and gh at 18:00 UTC, unless the cell
says otherwise. The order follows what each serves: slots that finish first, then the comparisons, then the gate.

| # | Item | Serves (vision.md) | Metric, reading | Narrow check |
|---|------|--------------------|-----------------|--------------|
| 1 | Paddock on asus, tracked by [#874](https://github.com/sammasak/nixos-config/issues/874). A measure: done (#838 ladder). B model fit: the 35B Q4 pinned at config C (max_batch 4, context 16384), the setting Pi uses. C real use, started 26 Nov: config C serves up to four Pi agents at once (9 slots, 12 guaranteed checkpoints; single-turn 22.1 tok/s at 16384, 23.6 at 8192, 24.2 at 4096); four real Pi agents ran at once with no starvation and no call cut by length, at 13.4 tok/s total and 2.8 to 4.1 tok/s a call with 3 to 4 decoding (19.4 alone). C's target: 20 local-lane tasks served through llm-gateway, local share at least 50 percent, 7 days of tok/s, TTFT, gate passes, failures, GPU watts and restarts. D harden: the served head passes the CPU gate and strict GPU gates with no `PADDOCK_*` pins; the standalone flake (PR 10) built on asus, the runner in 48.8 min and bit-identical on `--rebuild`, the sm_86 CUDA pack in 12.3 min (#874, 17:37 UTC); serving from the flake build and a build on acer are open. E upstream: per-piece evidence in #874, proposing only; weekly upstream sync (brief 82). | "a large model can run on modest hardware" | total tok/s at 4 and 8 sessions (#838, 26 Nov): 35B Q4 pinned 15.8 / 16.4, 35B disk-backed 22.6 / 22.6 (serial), 122B Q2 disk-backed 3.1 / 3.7 (serial). Best single session: 35B 26.6, 122B 3.9; at 16 sessions 35B about 26 total, 122B no failures. paddock PRs 4 to 14 merged into asus/biggest-moe, 15 in re-review at 18:00 UTC; ahead and behind upstream main unread | the same ladder rows on asus, sessions 4 and 8; four Pi agents at once at config C, max_ctx 16384: tests pass, no call cut by length |
| 2 | herman [#62](https://github.com/sammasak/herman/issues/62): an unmarked amendment no longer resolves on its marked sibling's citation. herman PR 90 reviewed at 7/10 and sent back (17:01 UTC): it fixes the same-family, same-date shape only; cross-date and cross-family siblings still resolve, and two sections pinned before (0089, 0092) drop out of the pin. The review's smallest fix: count a bare-keyed section as residual when its record has any other post-tag section (`RECORD_LEVEL` 7 rows to 13) and add a red control for the cross-date shape | "Only safety, or \"does not fix the problem\", blocks a change": a gate with a hole nobody pinned | bare-keyed sections beside a marked post-tag sibling and pinned nowhere: 6 at PR 90's head (the review); herman #57's control shipped as herman 89 | `cargo test -p herman-app --test changelog_records_every_post_tag_amendment`, 4 tests to 5 |
| 3 | A session may mark only its own PR ready ([#653](https://github.com/sammasak/nixos-config/issues/653), pool finding 9); PR creation is held to the task's branch since #914 (deployed acer and msi) | "Agents run in disposable sandboxes that hold no credentials" | refused PR creations per day, 0 expected (`exec_pool_push_filter_pulls_total{result}`): unread; one passed and one refused PR creation on a host after #914's deploy: not yet run | the `exec-pool-push-filter` check with a ready-mark of another task's PR |
| 4 | The flake check as one evaluation run: its per-output `nix eval` processes as one `nix-eval-jobs` run ([#835](https://github.com/sammasak/nixos-config/issues/835)). PR 918 is a draft: nix-eval-jobs refused acer's and msi's deploy-activate and deploy-schema checks at every budget up to 6 GiB (as separate processes they peak at 4.2 GiB), so it does not fit acer's memory budget; next is the deploy pairs in their own processes and the rest through nix-eval-jobs, or drop the follow-up | "No dedicated benchmarks, no long test rituals" | per-output evaluation 840 s in the 26 Nov 07:07 UTC flake check, 1102 s at 03:20; PR 918 on msi: 1208 s the old way, 809 s with nix-eval-jobs at 2 x 2048 MiB but 5 checks failed | the flake check's gate-step records: the same checks listed, `eval_seconds` summed lower |
| 5 | Shunt ([#625](https://github.com/sammasak/nixos-config/issues/625)) by 2 Dec | "Every change ships behind a switch ... judged on the running system" | 25 Nov 17:00 UTC: pool1 Shunt 8 turns, 0.89 USD a turn, Shunt acted on none | none to run: read the Shunt per-arm series and decide by 2 Dec |

Next after the queue, in order: alert investigations with a cause ([#624](https://github.com/sammasak/nixos-config/issues/624), its inventory shipped in #915,
[#825](https://github.com/sammasak/nixos-config/issues/825), [#826](https://github.com/sammasak/nixos-config/issues/826)),
and #835's shared host evaluation and the gate alone on acer (Check tuning's follow-ups).

Anti-starvation: [#14](https://github.com/sammasak/nixos-config/issues/14) (opened 3 Oct) had its change shipped in
#878 and stays open for its last checks (Later); herman#57 (13 Nov 18:40) shipped as herman 89, and herman#62
(13 Nov 20:58) is the oldest runnable, item 2.
llm-gateway#69 (23 Oct) is blocked; skills#104 (13 Nov) has its change merged (skills #172), and
devenv-platform#129 (13 Nov 00:18) its step A (PR 167).

Worked by the efficiency-plan session, not by the pool: nixos-config issues 896, 897, 899, 900, 901, 902 and 903
and skills 177 (PRs 906, 907, 909, 912 and 916, merged 17:59 to 18:06 UTC, and #911 for 902; 900 and 903 still open).

In flight (not next): PR 918, a draft (item 4); PR 913, a turn with tokens and no cost growth is unpriced (deploy
acer, msi); slot memory kills (#827): `increase(exec_pool_memory_kills_total[18h])` at 18:00 UTC reads acer 55 and
msi 35 for 26 Nov, msi's all between 16:45 and 17:40 UTC (#827's 18:12 UTC comment reads msi at 0, which the counter
does not bear out), PR 922 open at 18:00 (merged at 18:17); herman PR 90 sent back at 7/10 (item 2).

Shipped on 26 Nov, 10:00 to 18:00 UTC:
- Main green again: #864 (grafana-dashboards) and #869 (`scripts/test-deploy-recipes.py` answers the drain probe from
  its fixture, #863).
- Cargo under the lock: #876, a slot's cargo capped to one job per GiB of slot memory; deployed acer and msi.
- AdGuard's DNS ports on lenovo scoped to the LAN and the tailnet: #878, deployed lenovo; #14 stays open for a
  tailnet query and a refusal check from outside.
- The merge check runs `nix flake show` on the merge: #880.
- One lenovo deploy at a time: #873.
- The 300K window (#626) decided: rejected in #875 at 1.20x default's USD and 1.30x its tokens per turn (46 turns
  against 57, Shunt off on both); pool2 back to the default.
- The scheduled gate three runs a day (03:20, 11:20 and 19:20 UTC) and the ship rule in the repository: #872.
- store-upload.path's start limit on msi: #881.
- herman's advisory fix: herman #87, its waivers tracked in herman #88.
- pi-harness #27.
- Also merged: #861 (a slot's nix build, flake check and `--file`/`--expr` evaluations under the light lock;
  deployed acer and msi), #862 (skills d335f68, the heavy-build hook on lenovo), #866 (a first prompt no Enter
  submitted ends the turn), #860 (the turn errors row), #882 (test scripts stop naming goals.md); devenv-platform
  167, 168 and 169 (their issues #129, #155 and #141 still open); paddock PR 4.
- Pool panes: #883, one Herdr workspace per slot and `idleGraceSecs` 120 s; live after the slot hosts' deploy.
- Pool task capabilities (#859's nixos-config half): #886 (`--requires`) and #892 (every slot offers
  `host-<hostName>`; briefs write `--requires host-acer-swift`, not `host:`).
- test-qa-push reads the flake check's kinds from `scripts/flake-output-kinds.json`: #887.
- A slot commits and pushes through `devenv shell` where a devenv.nix exists (pool finding 13): #888.
- The 300K window's rejection in the docs: #889; dashboard panel 62's text: #893.
- The 15:00 queue update: #890.
- StoreUploadStale, a sender's upload textfile stale or gone: #891.
- lenovo's evaluation fails on a skills pin without its heavy-build guard: #894 (after #884, #865).
- RetroDueStepFailsRepeat clears once main passes the step again: #895.
- seventh-host evaluates each host once unless an assertion fails: #885.
- factum 65: devenv-platform pin to 358f2c2.
- paddock PRs 6, 8, 9, 10 and 11, all merged into asus/biggest-moe: the default plan seats the slot cache at max_batch
  16 (6), the prefix-resume gate pinned and exposed as `[prefix_resume]` (8), metrics for checkpoint steals, expert
  slot hits, queue depth and fresh/resumed TTFT (9), a standalone flake for the runner and CUDA pack (10), the eg2
  picture tests skip without reference media (11).
- herman 89: #57's executed negative control for `no_source_paths`.
- Check tuning rows from the gate-step records: #908 (`scripts/check-tuning.py`, #837; not yet run by nixos:qa).
- A pool reset keeps the slot's nix-cache and eval-cache: #910 (#898's reset part; the clone mirror was dropped,
  #917 closed); deployed acer and msi.
- Shipping phases: #911 (#902): a PR's gate is its first passing full gate, fast push or pool merge check, and
  merge-to-deploy is per host; its live run read `shipping_pr_phase_unmatched{reason="no_gate"}` 6, where the issue
  counted 221, and 89 PRs with a gate phase; deployed lenovo.
- A slot's pull request only from its own task branch: #914 (#653); deployed acer and msi.
- The alert inventory, #624's first slice: #915 (`docs/monitoring.md`, 27 alert names, 7 with a known signal, route
  and receipt).
- NodeSystemdCollectorFailed: #919; deployed black-pi.
- skills 178 (`requires` on `pool:start` and `pool:submit`, #859 point 3) and 179 (the coordinator's in-session graded
  review); the nixos-config pin bump #921 and then #906 merged at 18:06 UTC.
- paddock PRs 5, 7 (a sync of truespar/paddock main 977372b), 12, 13 and 14, merged into asus/biggest-moe: TTFT ends
  at the first token and the pinned MoE slot counters are exported (12), also for a chat stream cut by a stop string
  (13), checkpoints shared across sequences are held against steals (14). PR 15 was in re-review at 18:00 UTC (9/10
  and merged at 18:14).

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

#### Next lane tasks (run when asus serves a local model again)

On lenovo (it has `exec-pool`, `claude` for the review and a `gh` login), one at a time:

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

`nixos-config-bench-qwen` runs on acer as lukas (lenovo cannot run its lint, pool finding 6) with
`LOCAL_LANE_STATUS=http://127.0.0.1:9091/status` and the `--scope`, `--lint` and `--task` from the PR #816 comment.
With no local model up every command exits 3 with "no local model up" and submits nothing.

## Open pool findings (epic #646, in pick-up order)

1. Slot memory kills: the slots share one `environments.slice` limit (acer 9G of 15 GiB, ollama 4G). acer fired
   ExecPoolSlotMemoryKills and NodeOOMKill at about 09:50 UTC on 26 Nov with four slots busy, 15 kills in an hour.
   Cause (coordinator, 26 Nov): a direct `cargo build` in pool1 with no lock filled the 9 GiB slice for about 90 s.
   #830, #833, #843 and #861 put a slot's nix evaluations and builds under the light lock, and #876 caps a slot's
   cargo to one job per GiB of slot memory (deployed acer and msi). This realignment's own turn in acer pool1 was one more such kill (nix, dbus-broker and claude killed
   during its push hook's gate probe). The kills count against keeping pool4: decide it with the heat comparison on
   27 Nov (Hosts and slots).
   A goals.md-only push ran a test script whose comment named goals.md, so it built the gate probe, a full host
   evaluation; #882 stops the test scripts naming goals.md.
2. A session's first prompt can stay unsubmitted and hold a slot for an hour; lost twice on 26 Nov. #866 ends a turn
   whose first prompt no Enter submitted (merged 10:42 UTC, live after the slot hosts' deploy).
3. A finished session holds its slot for ten idle minutes (`idleGraceSecs` 600). Fixed by #883, 120 s (merged 14:15
   UTC, live after the slot hosts' deploy).
4. Each slot shows two Herdr workspaces, one always empty (owner noticed). Fixed by #883, one workspace per slot.
5. A deploy of asus restarts `paddock.service` and resets the GPU power limit, so it breaks a measurement day: no
   asus deploy while the agent `paddock` measures (26 Nov).
6. Two deploy evaluations at once on lenovo were killed (exit 137); #873 runs one deploy at a time. lenovo also cannot push nixos-config
   (stale devenv gate), and its root rebuild trigger needs a GitHub SSH key for root.
7. Sessions finish with no pull request: two on 26 Nov. Briefs now end with a footer sentence asking for the PR; the
   signal is a finished session whose branch has no PR.
8. A task can be dispatched to a slot that lacks what it needs (#859). Fixed by #886 (`--requires`) and #892
   (`host-<hostName>`); the skills side is in Later.
9. A pull request's head was not held to the task's branch ([#653](https://github.com/sammasak/nixos-config/issues/653)).
   Fixed for PR creation by #914 (deployed acer and msi); the ready-mark is item 3. The push filter is live on both
   hosts, and acer's slots run with `slot.privateUsers` (hosts/acer-swift/configuration.nix).
10. pi-harness is not in the pool's repository list, so a slot cannot clone it (and its issues answer 403 over REST);
    fix in flight, the pi-harness #26 bump waits on it.
11. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.
12. Turn errors per arm (`exec_pool_session_turn_errors_total{host,variant,shunt,agent}`, #851) are counted; the row in
    the Agent harnesses comparison table merged in #860.
13. A pool session's push from a fresh clone ran no hooks because no hooks path was set (seen on PR #867), so
    pre-push checks may be skipped in slots. Fixed by #888: the prompt requires commit and push through `devenv shell`.

## Check tuning

Owner, 25 Nov: "keep count of how we can fine tune testing so that we can have some small and fast checks applied and
only run long gates even less often". Per-step seconds sit in Loki's `{job="platform",kind="gate-step"}` records
(`gate="nixos-qa"` or `gate="pool-merge-check"`); #849 reads this table's minutes from them. "Caught" means a fix
commit or pull request names the check as what failed.

The full gate runs only as the scheduled gate (acer, 03:20, 11:20 and 19:20, when main moved) or `just full-gate`.
Owner, 26 Nov: a pull request ships on its session's narrow check on its own head and a textually clean merge; nobody
re-runs a merge check on current main, and the scheduled gate, eight hours apart, is the backstop for two that merge
cleanly but break each other. `just pool-merge-check` stays for a session that wants it; it picks its checks from
the changed paths (`scripts/pool_merge_check.py`; docs: nothing) and
writes one gate-step record per check. The last full run (26 Nov 12:49 to 13:59 UTC, head `36ccc813`, 4216 s) was red
on `seventh-host-test` alone (519 s): the AdGuard anchor that 0d097762 moved, fixed by #885 after that head; the
steps after it did not run. Its gate probe took 244 s, the flake check 2357 s and workers-eval-test 816 s. Next full
run: the 19:20 scheduled gate.

Under the ship rule (26 Nov, 11:00 to 15:00 UTC): 14 pull requests merged with no bounce for a moved main. Sessions
returned without the review line four times; the brief footer was reworded at 13:55 UTC.

Checks recorded in the merged pull request bodies, 26 Nov 14:00 to 16:00 UTC: #883 `nixos:exec-pool-test` 252 s
and `nixos:workers-eval-test` 535 s, caught nothing; #884 `nixos:coordinator-test` 45 s and a seeded case (not
stated), caught nothing; #885 seventh-host-test whole 382 s (6.4 min) plus four alternated probe runs (165, 109, 98
and 69 s), caught the AdGuard anchor that 0d097762 moved (red on main) and the old code's OOM kill on acer-swift's
seeded evaluation; #886 the crate tests and the workers evaluation, not stated, caught nothing; #887
`python3 scripts/test-qa-push.py` about 9 s, caught its own stale stub (1 failed before the fix); #888 `cargo test`
for pkgs/exec-pool 4.8 min with clippy and `--test agent` 0.3 min, caught nothing (a fresh-clone measurement showed
`core.hooksPath` dirties the tracked shims, so that approach was reverted); #889 `just lint-comments` and the
pre-push docs set, not stated, caught nothing; #890 `just lint-comments` 3 s inside a 56 s devenv shell, caught
nothing; #891 `promtool test rules` on `modules/homelab/monitoring/rules/tests/store-upload.yaml` and `check-alert-annotations.py`, not stated, caught
nothing (the new cases fail against main's rules, as meant); #892 `nix build .#exec-pool` 12 min 54 s and
`nixos:workers-eval-test` 15 min 47 s, caught nothing; #893 `python3 -m json.tool` and the pre-push hook, not
stated, caught nothing; #894 `nixos:coordinator-test` 1.1 min and a seeded evaluation 0.5 min, caught nothing;
#895 `python3 scripts/test-shipping-metrics.py` (not stated) and `nix build .#checks.x86_64-linux.shipping-rules`
480 s, plus 370 s on main's rule, caught nothing on the head (the new case fails on main's collector and rule, as
meant); factum 65 `devenv shell -- true` 1.4 min and `sdlc:done` (sketch 2.6, model 1.3, test 17.2 min, security
1.6 s), caught nothing. #864 already reads store-upload's series names from `modules/core/store-upload.nix`, so the
#857 escape row is removed. No body names a failure that no check caught.

Total stated: about 101 minutes (6045 s) over 10 bodies; #886, #889, #891 and #893 state no time.

Checks recorded in the merged pull request bodies, 26 Nov 16:00 to 18:00 UTC: #908 `python3
scripts/test-check-tuning.py` (12 PASS) and ruff, not stated, caught nothing; #910 `dev-env-reset-vm` 137 s and its
negative control 128 s (failing, as meant), caught nothing; #911 `python3 scripts/test-shipping-metrics.py` about 1 s
and a live run about 3.5 min, caught nothing; #914 the `exec-pool-push-filter` check about 1 min,
`scripts/test-workers-eval.py` 20 min in full and 3.5 min on the touched part after a full run was OOM-killed in the
slot, and `just pool-merge-check` 10 min; the full workers-eval run caught the catch-all 403 ordered first in the
slot site (fixed in 1f5672fa); #915 pre-commit and the pre-push docs set, not stated, caught nothing; #919
`monitoring-rules-tests` 6.3 min and `promtool test rules` 2.3 min, caught nothing (the new cases fail on main's
rules, as meant). Total stated: about 51 minutes over 4 bodies; #908 and #915 state no time. No body names a
failure that no check caught, so no escape row is added.

| Check or step | Typical minutes | Real defects caught (commit or PR) | Depends on |
|---|---|---|---|
| Whole scheduled gate | 26.0 mean over 7 runs to 26 Nov 03:20, 90.1 worst (03:20); 63.1 on 26 Nov 07:07 UTC, red; 70.3 on 26 Nov 12:49 UTC, red; "40 min build time is crazy" | 6 reds: `shunt-metrics-test` (#759), `execution-pool-vm` evaluation (#795), `grafana-dashboards` (#814), `legacyPackages` output kind (#828), `ollama-gpu-test` (#855), `seventh-host-test` on the AdGuard anchor (#885) | everything |
| lint-comments, lint-shell, deploy-rs-pins | seconds (5, 3 and 1 s on 26 Nov) | lint-comments 9d7cec2a (#800); shellcheck d947c2a2 (#795) | `.nix`, `.sh`, `.py`; `scripts/*.sh`; devenv and flake locks |
| fmt-check | 8 s on 26 Nov | 747a1f71 (#684) | every `.nix` |
| secrets-verify | 0 s in records | none traced | `secrets/` |
| nixos-push-eval (`nix flake show`) | 2.3 mean over 264 (7 d; 3.9 GiB, acer); 1.5 to 5.5 on 26 Nov | 24cb9892 (#797) | every flake output's attribute set |
| gate probe | 4.2 mean over 90 (7 d); 8.5 on 26 Nov 07:07 UTC | none traced | every host |
| nixos-flake-check | 14.7 mean over 91, 64.6 worst (7 d); 46.0 on 26 Nov 07:07 UTC: 939 s building (319 compiled, 8 fetched), 840 s per-check evaluation; 15 built, 27 present, 4 deferred to asus | `execution-pool-vm` (#795); ruff E501 (#787); exec-pool clippy and rustfmt; `legacyPackages` (#828); a failed output listing (#856) | every check and every x86 host |
| workers-eval-test | 2.1 mean (7 d); 6.2 on 26 Nov 07:07 UTC | 0b90b42d (#781), f4fac5f5 (#736); acer-only failure (#825), the test reads no host state outside its temp dir since #848 | gate probe, `modules/workers/` |
| seventh-host-test | 3.2 mean (7 d) | none traced | hosts.nix, fleet.nix, every host |
| shunt-metrics-test | 0.1 (7 s mean over 28) | df0f5007 (#759) | probe, `scripts/shunt-metrics.py` |
| ollama-gpu-test | 0.03 (2 s; 16 s on #855's branch) | the seeded case pinned asus's MemoryMax 8G after cdd970b6 set 6G (#855) | `hosts/asus-b460m/`, the ollama module |
| deploy-recipes-test | 0.03 (1.9 s mean) | fails on a `github:` private input since #803; on acer it reaches the installed `exec-pool-drain` (#863) | Justfile, flake.lock |
| The other tests in `tests` (devenv.nix) | 3.8 summed over 45 steps; alloy-otlp 0.6, worker-permissions 0.5, qa-push 0.5, the rest under 0.4 | none traced | most read the gate probe |
| grafana-dashboards (in the flake check and pool-merge-check) | 2.6 mean built (57 of 83 flake-check runs); 3.6 on 26 Nov 07:07 UTC, rebuilt less since #849 | #814 | black-pi's dashboards and rules, what it reads at evaluation |
| execution-pool-vm | 6.1 built on 26 Nov 07:07 UTC (45 compiled), 11.7 on 26 Nov 03:20 | `execution-pool-vm` (#795) | `modules/workers/`, `pkgs/exec-pool/` |
| pool-merge-check: host evaluation | 57 s mean over 461 evaluations, 441 min in 24 h (to 26 Nov 10:00 UTC) | lenovo's sam.memory budget (#794, #799) | the host's modules and `hosts/<dir>/` |
| pool-merge-check: package build | 162 s mean over 27 builds in 24 h | c15a3024 (#795) | `pkgs/<dir>/` |

The slowest, by minutes (26 Nov), with the cut for each:
1. Host evaluation: pool-merge-check's 441 min in 24 h and the gate probe's 507 s a run, plus seventh-host and
   workers-eval evaluating the hosts again. Cut: one shared evaluation (about 400 s a gate, follow-up 2 below). #849's path
   scoping (a `scripts/test-*` change evaluates no host) is live.
2. The flake check under slot load: 2759 s on 26 Nov against 1373 s on 24 Nov, with four acer slots evaluating
   beside it and 15 slot memory kills in an hour. Cut: the gate alone on acer (follow-up 1 below), and cargo under the lock (#876).
3. The VM tests: execution-pool-vm 367 s, dev-env-reset-vm 68 s, runtime-host-role-vm 48 s built on 26 Nov. #853
   made them checks only (no second evaluation as packages), merged 08:26 UTC, after the 07:07 run started. Narrow
   check: the 19:20 run's `eval packages.*` lines in the gate journal.

Main was red at 11:00 UTC on two checks: grafana-dashboards waited for store_upload series that never appear (from
#857; fixed by #864), and one case of `scripts/test-deploy-recipes.py` on acer (#863; fixed by #869).

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

Owner, 25 Nov: "anytime a worker builds something it should be put into the cache". acer's slots build through acer's
daemon into the store its harmonia serves, and lenovo substitutes from acer. `modules/core/store-upload.nix` (#839)
has msi and asus queue each built output with a `post-build-hook`; acer pulls the paths from the sender's harmonia
and keeps them under gcroots, 14 days and 100 GiB. StoreUploadStuck (#857) fires on a sender's queue acer does not
take.

Follow-ups, in order: (1) the scheduled gate alone on acer; (2) one evaluation of every host shared by the probe,
the flake check and seventh-host; (3) the flake check's per-output `nix eval` processes as one `nix-eval-jobs` run
(item 4); (4) acer's max-jobs and cores (2 and 2) against the memory budget: decided in #835 (26 Nov 14:37 UTC), keep
2 and 2 on every runtime host, no change.

### Escapes still without a narrow check

| Escape | Smallest check that would catch it |
|---|---|
| #777: every pane turn on acer failed with a herdr parse error | one session turn through a pane on a slot before the merge |
| cdd970b6 set asus's MemoryMax to 6G with Paddock on; `ollama-gpu-test` still expected 8G and the scheduled gate went red (#855) | pool-merge-check running `scripts/test-ollama-gpu.py` (16 s) for `hosts/asus-b460m/` and the ollama module |

Rule for every session: a reply states the minutes of each check it ran and what any failure caught. An escape gets
a row above and a narrow check, not a longer gate.

## Later (not queued; one line each)

- [#836](https://github.com/sammasak/nixos-config/issues/836) follow-ups to the inside names (`<listener>.fleet.sammasak.dev`, #850, live on black-pi, acer, msi and lenovo): Grafana's API is admitted from the edge alone (widen `from` is the owner's call, it still needs a Grafana login); the slots reach Prometheus, Alertmanager and Loki through their host's read-only proxy, not by name; an unlisted name in the zone falls to the edge's 404; the per-name probe (one curl per inside name from black-pi) is the metric still unread.
- Local-model lane and the ledger ([#807](https://github.com/sammasak/nixos-config/issues/807), [#806](https://github.com/sammasak/nixos-config/issues/806), epic [#491](https://github.com/sammasak/nixos-config/issues/491)): 3 passed lane tasks; the next ones above run when asus serves a local model again (the GPU is on the ladder, item 1). Check: `nixos:local-lane-test` (about 15 s).
- [#653](https://github.com/sammasak/nixos-config/issues/653) slice 4 (per-task tokens) is needs-owner; the rest is item 3.
- [#834](https://github.com/sammasak/nixos-config/issues/834), skills [#167](https://github.com/sammasak/skills/issues/167), [#168](https://github.com/sammasak/skills/issues/168): Shunt pilots for Codex and Pi, one-shot boilerplate, a local bulk-read backend; after item 5 decides Shunt.
- skills [#176](https://github.com/sammasak/skills/issues/176): the owner-only list (deploy, tag, secrets) differs between the global context and the coordinator role.
- skills [#104](https://github.com/sammasak/skills/issues/104) and [#128](https://github.com/sammasak/skills/issues/128): their changes merged (skills #172, #175); close them once a slot's review uses the shipped prompts.
- [#611](https://github.com/sammasak/nixos-config/issues/611): native OTLP requests above 1 MiB; fix #613 merged, relay rejections per day unread.
- [#600](https://github.com/sammasak/nixos-config/issues/600): the milestone that #864, #869, #876, #880 and #875 report to.
- paddock PRs 1, 2 and 3 (drafts: Nix setup, SSD expert backing RFC, steps 2 to 4): fold into the direction plan (item 1).
- llm-gateway [#69](https://github.com/sammasak/llm-gateway/issues/69): request id in a header, blocked.
- factum [#61](https://github.com/sammasak/factum/issues/61), herman [#76](https://github.com/sammasak/herman/issues/76): lane supply.
- herman is parked for the platform sprint: #1, #3, #7, #9, #10, #11, #14, #15, #21, #22, #25, #27, #29, #30 and #85.
- pi-harness: its issues answer 403 over REST, unread beyond #26 (after the queue; pool finding 10).
- asus is behind main: its deploys were held on 26 Nov while the GPU limit is raised for measurement; catch up on 27 Nov.
- ExecPoolSlotMemoryKills: read it again after #876's deploy on acer and msi.
- asus's root disk is at 85 percent from the ladder's model files; the 397B files are being removed.
- [#14](https://github.com/sammasak/nixos-config/issues/14): a query from the tailnet and a refusal check from outside, after #878.
- pi-harness [#26](https://github.com/sammasak/pi-harness/issues/26) can close: its pin is already devenv-platform main 358f2c28.
- devenv-platform [#155](https://github.com/sammasak/devenv-platform/issues/155): its change merged as PR 168; close it after a Loki reading shows no text fields.

## Horizon (direction only, no work scheduled)

- The pool as a coding platform: any repository, guest users (vision.md).
- The app platform, epic [#557](https://github.com/sammasak/nixos-config/issues/557): next step is to register one
  real app. Apps in the registry today: 0.
- devenv-platform#156 to #166, workload orchestration research (`horizon`): vision.md names no container orchestrator.

## needs-owner (what no agent can do)

| Issue | What is needed |
|---|---|
| skills PR 169 (review in [skills#170](https://github.com/sammasak/skills/issues/170), labelled `approved`) | the owner's approval to merge |
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
| acer-swift | `pool1` to `pool4` | Shunt on `pool1`; `pool4` light (1G reserve, CPUWeight 100 against 200, CPUQuota 200%), the slice 9G; offers claude and pi, and codex on the owner's ChatGPT login; last deploy 26 Nov 17:40 UTC at `e91e252e` (#914) |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30; deployed main's head `e43b7dcb` (#906) at 18:16 UTC, so it owes no deploy tonight (the deploy records in Loki against origin/main's merges) |
| asus-b460m | none | ollama (one resident model, 130 W cap), `paddock.service` (Qwen3.6 35B, #817, #822), agent `paddock`; off 21:00 to 08:30. 26 Nov: `paddock.service` stopped and the GPU at 270 W for the ladder (#838); it owes the deploys of #850 and the merges after #858 on purpose, no asus deploy on 26 Nov (pool finding 5). Its deploys are owed on 27 Nov: at 18:15 UTC `shipping_pr_not_deployed` reads 35 PRs and `shipping_deploy_lag_commits` 158 |

Heat, the extra slot's price (owner, 25 Nov 23:50). Before, 25 Nov 23:50 with three acer slots busy: acer 8 cores, load
5.0, 11.3 GiB available of 15.6, environments.slice 2.5 of 7 GiB, package 66 C now and 94 C peak in 6 h,
node_cpu_core_throttles_total up about 888,000 in 6 h, no fan sensor; lenovo 16 cores, load 0.3, 10.9 GiB available
of 15.7, user.slice 4.3 of 8.4 GiB, 49 C now and 100 C peak in 6 h, fans 0 rpm idle (its 65535 peak is the sensor's
error value). After, 24 h past the pool4 deploy: acer's throttle increase over 24 h and peak temperature with four
slots against the 24 h before that deploy with three (the Hosts dashboard's heat row;
`sum(increase(node_cpu_core_throttles_total{node="acer-swift"}[24h]))` and `max_over_time(homelab:node:hwmon_temp_max_celsius{node="acer-swift"}[24h])`).
Decide on 27 Nov with pool finding 1's memory kills: if acer's throttling rises by more than half, or the kills stay
at the 26 Nov rate, drop pool4 again (`slots = 3`, `light.slots = 0`). lenovo's first slot is not in this layout yet.

No slot holds a GitHub key: slots push through acer's GitHub sidecar and private clones go through the proxy.
Gaming entries on asus and msi are merged and booted on neither host yet; the owner accepted them untested (#645).
