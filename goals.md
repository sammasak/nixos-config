# Goals: one priority queue

The direction this queue serves: [vision.md](vision.md). Realigned on 26 Nov 2026, 11:10 UTC, against vision.md and
every open issue and pull request in the nine repositories (pi-harness answers 403 over REST, so its issues are
unread). What shipped is in git history and the closed issues.

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
- "40 min build time is crazy": a gate that long is a defect to fix (item 7 and Check tuning's follow-ups), not a cost to accept.
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

Readings at 26 Nov 10:00 to 11:00 UTC from black-pi's Prometheus and Loki (a slot reads them at `$PROMETHEUS_URL`
and `$LOKI_ADDR`) and gh at 11:10 UTC, unless the cell says otherwise. Items 1 to 8 and 10 are the coordinator's
order behind the slots (12:00); the order follows what each serves: a green main and slots that finish first, then
the gate, then the comparisons.

| # | Item | Serves (vision.md) | Metric, reading | Narrow check |
|---|------|--------------------|-----------------|--------------|
| 1 | Main green again: `scripts/test-deploy-recipes.py` on acer reaches the host's installed `exec-pool-drain` ([#863](https://github.com/sammasak/nixos-config/issues/863)) | "Every change ships ... judged on the running system": a red main gates nothing | 1 FAIL of 26 on acer at origin/main ("a host without exec-pool-drain is deployed without a drain"); grafana-dashboards, the other red, is fixed by #864 | `python3 scripts/test-deploy-recipes.py` on acer, 26 PASS (seconds) |
| 2 | Cargo under the lock: a slot's `cargo build` takes the light lock like its nix evaluations (brief 70; [#827](https://github.com/sammasak/nixos-config/issues/827)) | "Agents run in disposable sandboxes" that finish their work | `increase(exec_pool_memory_kills_total[1h])` on acer at 10:00 UTC: pool1 11, pool2 4, pool3 3, pool4 4; cause, one unlocked cargo build in pool1 filled the 9 GiB slice for about 90 s (pool finding 1) | the exec-pool wrapper's own test with a `cargo build` case; the counter flat on acer for a day after the deploy |
| 3 | Pool panes: one Herdr workspace per slot, and `homelab.execPool.idleGraceSecs` from 600 s to 120 s (pool findings 3 and 4) | "Agents stay visible and steerable"; "costs nothing while it waits" | Herdr workspaces per slot: 2, one always empty (owner, 26 Nov); a finished session holds its slot 600 s idle | the exec-pool crate's pane tests; one session on a slot shows one workspace and frees the slot within 120 s |
| 4 | Pool task capabilities: a task names what it needs and is started only on a slot that offers it ([#859](https://github.com/sammasak/nixos-config/issues/859)) | "Work is one queue with priorities" that finishes | tasks dispatched to a slot lacking what they need: 1 in the 26 Nov usage report (a review without the SSH access it needed) | `cargo test` for the dispatch preflight in `pkgs/exec-pool` |
| 5 | AdGuard's DNS ports on lenovo answer the LAN and the tailnet only, by an explicit rule ([#14](https://github.com/sammasak/nixos-config/issues/14), anti-starvation, 3 Oct) | "DNS stays up"; "Upstream modules before home-made services" | open entries outside `lib/firewall.nix` and `fleet.nix`: 2 (`modules/homelab/adguardhome.nix` 53/udp and 853/tcp); 53 and 853 are `sam.fleet.public` on every interface | `adguard-dns-test`; one `dig` from the LAN, and none answered from another interface |
| 6 | herman [#57](https://github.com/sammasak/herman/issues/57): an executed negative control for `no_source_paths` (anti-starvation, 13 Nov) | "Only safety, or \"does not fix the problem\", blocks a change": a guard nobody has seen fail | executed controls for `no_source_paths` in `tools/perf-metrics/gate-tests.sh`: 0; the lane task above holds the exact change | `tools/perf-metrics/gate-tests.sh`, `EXPECTED_CHECKS` raised by 2 |
| 7 | Gate speed: `nix flake show` on the merge in pool-merge-check ([#835](https://github.com/sammasak/nixos-config/issues/835); the #793 and #796 escape) | "No dedicated benchmarks, no long test rituals" | escapes of main's evaluation past pool-merge-check: 2 (#793, #796); nixos-push-eval 1.5 to 5.5 min on 26 Nov | `scripts/test-pool-merge-check.py` with a case that breaks evaluation only on the merge |
| 8 | One deploy from lenovo at a time: a second deploy evaluation waits instead of both being killed (pool finding 6) | "A piece of work can stop for a review, a deploy ... and continue" | concurrent deploy evaluations killed on lenovo (exit 137): 2 on 26 Nov | `scripts/test-deploy-recipes.py` with a second deploy started while one holds the lock |
| 9 | Paddock on asus, tracked by [#874](https://github.com/sammasak/nixos-config/issues/874). A measure: done (#838 ladder). B model fit: the default plan does at least 26 tok/s single session on the 35B with no env switches, and a named model passes at least as many local-lane gate tasks as the 35B. C real use: 20 local-lane tasks served through llm-gateway, local share at least 50 percent, 7 days of tok/s, TTFT, gate passes, failures, GPU watts and restarts. D harden: the served head passes the CPU gate and strict GPU gates with no `PADDOCK_*` pins. E upstream: per-piece evidence in #874, proposing only; weekly upstream sync (brief 82) | "a large model can run on modest hardware" | total tok/s at 4 and 8 sessions (#838, 26 Nov): 35B Q4 pinned 15.8 / 16.4, 35B disk-backed 22.6 / 22.6 (serial), 122B Q2 disk-backed 3.1 / 3.7 (serial). Best single session: 35B 26.6, 122B 3.9; at 16 sessions 35B about 26 total, 122B no failures. 397B rung next; paddock PR 4 (plan step 1) merged into asus/biggest-moe; 79 ahead, 1 behind upstream main (26 Nov) | the same ladder rows on asus, sessions 4 and 8 |
| 10 | The 300K window decision ([#626](https://github.com/sammasak/nixos-config/issues/626)); Shunt ([#625](https://github.com/sammasak/nixos-config/issues/625)) by 2 Dec | "Every change ships behind a switch ... judged on the running system" | 25 Nov 17:00 UTC: pool3 default 13 turns, 0.19 USD a turn; pool2 300K 12 turns, 0.15 USD; pool1 Shunt 8 turns, 0.89 USD, Shunt acted on none. The read date (26 Nov 10:10 UTC) has passed | none to run: read the per-arm series and decide |

Next after the ten, in order: acer's build jobs and cores (2 and 2) against the memory budget; the flake check's
per-output `nix eval` processes as one `nix-eval-jobs` run (#835); a PR head bound to the task's branch
([#653](https://github.com/sammasak/nixos-config/issues/653)); then herman [#62](https://github.com/sammasak/herman/issues/62),
pi-harness [#26](https://github.com/sammasak/pi-harness/issues/26) once pi-harness is in the pool's repository list
(pool finding 10), [#865](https://github.com/sammasak/nixos-config/issues/865) (the heavy-build hook registered
without its pathExists condition), alert investigations with a cause ([#624](https://github.com/sammasak/nixos-config/issues/624),
[#825](https://github.com/sammasak/nixos-config/issues/825), [#826](https://github.com/sammasak/nixos-config/issues/826)),
and #835's shared host evaluation and the gate alone on acer (Check tuning's follow-ups).

Anti-starvation: [#14](https://github.com/sammasak/nixos-config/issues/14) has waited longest (opened 3 Oct), item 5;
herman#57 (13 Nov 18:40) is next oldest runnable, item 6. llm-gateway#69 (23 Oct) is blocked; skills#104 (13 Nov)
has its change merged (skills #172), and devenv-platform#129 (13 Nov 00:18) its step A (PR 167).

In flight as pool sessions (not next): pi-harness in the pool's repository list; the turn errors row in the Agent
harnesses table (PR #860, unblocked by #864). Merged on 26 Nov since 10:00 UTC: #861 (a slot's nix build, flake check
and `--file`/`--expr` evaluations under the light lock; deployed acer and msi), #862 (skills d335f68, the heavy-build
hook on lenovo; being deployed), #864, #866 (a first prompt no Enter submitted ends the turn); devenv-platform 167,
168 and 169 (their issues #129, #155 and #141 still open); paddock PR 4.

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
   #830, #833, #843 and #861 put a slot's nix evaluations and builds under the light lock; cargo is not covered:
   item 2. This realignment's own turn in acer pool1 was one more such kill (nix, dbus-broker and claude killed
   during its push hook's gate probe). The kills count against keeping pool4: decide it with the heat comparison on
   27 Nov (Hosts and slots).
   A goals.md-only push runs `scripts/test-fleet-contract.py` (its comment at line 73 names goals.md), which builds
   the gate probe, a full host evaluation, so a docs push costs a slot the memory of one. Cut: the comment says
   "docs" without naming goals.md, the way `scripts/test-pool-merge-check.py` uses placeholder doc names.
2. A session's first prompt can stay unsubmitted and hold a slot for an hour; lost twice on 26 Nov. #866 ends a turn
   whose first prompt no Enter submitted (merged 10:42 UTC, live after the slot hosts' deploy).
3. A finished session holds its slot for ten idle minutes (`idleGraceSecs` 600). Fix queued: item 3, 120 s.
4. Each slot shows two Herdr workspaces, one always empty (owner noticed). Fix queued: item 3.
5. A deploy of asus restarts `paddock.service` and resets the GPU power limit, so it breaks a measurement day: no
   asus deploy while the agent `paddock` measures (26 Nov).
6. Two deploy evaluations at once on lenovo are killed (exit 137): item 8. lenovo also cannot push nixos-config
   (stale devenv gate), and its root rebuild trigger needs a GitHub SSH key for root.
7. Sessions finish with no pull request: two on 26 Nov. Briefs now end with a footer sentence asking for the PR; the
   signal is a finished session whose branch has no PR.
8. A task can be dispatched to a slot that lacks what it needs: item 4 (#859).
9. A pull request's head is not held to the task's branch ([#653](https://github.com/sammasak/nixos-config/issues/653)).
   The push filter is live on both hosts, and acer's slots run with `slot.privateUsers` (hosts/acer-swift/configuration.nix).
10. pi-harness is not in the pool's repository list, so a slot cannot clone it (and its issues answer 403 over REST);
    fix in flight, the pi-harness #26 bump waits on it.
11. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.
12. Turn errors per arm (`exec_pool_session_turn_errors_total{host,variant,shunt,agent}`, #851) are counted; the row in
    the Agent harnesses comparison table is PR #860, in flight.

## Check tuning

Owner, 25 Nov: "keep count of how we can fine tune testing so that we can have some small and fast checks applied and
only run long gates even less often". Per-step seconds sit in Loki's `{job="platform",kind="gate-step"}` records
(`gate="nixos-qa"` or `gate="pool-merge-check"`); #849 reads this table's minutes from them. "Caught" means a fix
commit or pull request names the check as what failed.

The full gate runs only as the scheduled gate (acer, 03:20 and 15:20, when main moved) or `just full-gate`.
`just pool-merge-check` picks its checks from the changed paths (`scripts/pool_merge_check.py`; docs: nothing) and
writes one gate-step record per check. The last full run (26 Nov 07:07 to 08:10 UTC, head `0e525a45`, 3784 s) was red
on `ollama-gpu-test` alone, fixed by #855; the steps after it did not run. Next full run: the 15:20 scheduled gate.

| Check or step | Typical minutes | Real defects caught (commit or PR) | Depends on |
|---|---|---|---|
| Whole scheduled gate | 26.0 mean over 7 runs to 26 Nov 03:20, 90.1 worst (03:20); 63.1 on 26 Nov 07:07 UTC, red; "40 min build time is crazy" | 5 reds: `shunt-metrics-test` (#759), `execution-pool-vm` evaluation (#795), `grafana-dashboards` (#814), `legacyPackages` output kind (#828), `ollama-gpu-test` (#855) | everything |
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
   beside it and 15 slot memory kills in an hour. Cut: the gate alone on acer (follow-up 1 below), and cargo under the lock (item 2).
3. The VM tests: execution-pool-vm 367 s, dev-env-reset-vm 68 s, runtime-host-role-vm 48 s built on 26 Nov. #853
   made them checks only (no second evaluation as packages), merged 08:26 UTC, after the 07:07 run started. Narrow
   check: the 15:20 run's `eval packages.*` lines in the gate journal.

Main red at 11:00 UTC on two checks: grafana-dashboards waited for store_upload series that never appear (from
#857; fixed by #864, which unblocks PR #860), and one case of `scripts/test-deploy-recipes.py` on acer (#863, item 1).

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
(next after the queue); (4) acer's max-jobs and cores (2 and 2) against the memory budget (next after the queue).

### Escapes still without a narrow check

| Escape | Smallest check that would catch it |
|---|---|
| #793 and #796 each added the VM's gh stub, so main's evaluation failed | `nix flake show` on the merge in pool-merge-check (item 7) |
| #777: every pane turn on acer failed with a herdr parse error | one session turn through a pane on a slot before the merge |
| #857 named store_upload series grafana-dashboards waits for and that never appear; main red until #864 | a seeded case in the dashboards check: a gauge name read from its module, not typed |
| cdd970b6 set asus's MemoryMax to 6G with Paddock on; `ollama-gpu-test` still expected 8G and the scheduled gate went red (#855) | pool-merge-check running `scripts/test-ollama-gpu.py` (16 s) for `hosts/asus-b460m/` and the ollama module |

Rule for every session: a reply states the minutes of each check it ran and what any failure caught. An escape gets
a row above and a narrow check, not a longer gate.

## Later (not queued; one line each)

- [#836](https://github.com/sammasak/nixos-config/issues/836) follow-ups to the inside names (`<listener>.fleet.sammasak.dev`, #850, live on black-pi, acer, msi and lenovo): Grafana's API is admitted from the edge alone (widen `from` is the owner's call, it still needs a Grafana login); the slots reach Prometheus, Alertmanager and Loki through their host's read-only proxy, not by name; an unlisted name in the zone falls to the edge's 404; the per-name probe (one curl per inside name from black-pi) is the metric still unread.
- Local-model lane and the ledger ([#807](https://github.com/sammasak/nixos-config/issues/807), [#806](https://github.com/sammasak/nixos-config/issues/806), epic [#491](https://github.com/sammasak/nixos-config/issues/491)): 3 passed lane tasks; the next ones above run when asus serves a local model again (the GPU is on the ladder, item 9). Check: `nixos:local-lane-test` (about 15 s).
- [#653](https://github.com/sammasak/nixos-config/issues/653): a PR head held to the task's branch (pool finding 9); slice 4 is needs-owner.
- [#834](https://github.com/sammasak/nixos-config/issues/834), skills [#167](https://github.com/sammasak/skills/issues/167), [#168](https://github.com/sammasak/skills/issues/168): Shunt pilots for Codex and Pi, one-shot boilerplate, a local bulk-read backend; after item 10 decides Shunt.
- skills [#176](https://github.com/sammasak/skills/issues/176): the owner-only list (deploy, tag, secrets) differs between the global context and the coordinator role.
- skills [#104](https://github.com/sammasak/skills/issues/104) and [#128](https://github.com/sammasak/skills/issues/128): their changes merged (skills #172, #175); close them once a slot's review uses the shipped prompts.
- [#611](https://github.com/sammasak/nixos-config/issues/611): native OTLP requests above 1 MiB; fix #613 merged, relay rejections per day unread.
- [#600](https://github.com/sammasak/nixos-config/issues/600): the milestone items 1, 2, 7 and 10 report to.
- paddock PRs 1, 2 and 3 (drafts: Nix setup, SSD expert backing RFC, steps 2 to 4): fold into the direction plan (item 9).
- llm-gateway [#69](https://github.com/sammasak/llm-gateway/issues/69): request id in a header, blocked.
- factum [#61](https://github.com/sammasak/factum/issues/61), herman [#76](https://github.com/sammasak/herman/issues/76): lane supply.
- herman is parked for the platform sprint: #1, #3, #7, #9, #10, #11, #14, #15, #21, #22, #25, #27, #29, #30 and #85.
- pi-harness: its issues answer 403 over REST, unread beyond #26 (after the queue; pool finding 10).

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
| acer-swift | `pool1` to `pool4` | Shunt on `pool1`, 300K compaction window on `pool2`; `pool4` light (1G reserve, CPUWeight 100 against 200, CPUQuota 200%), the slice 9G; offers claude and pi, and codex on the owner's ChatGPT login; deployed 26 Nov with #861 |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30; deployed 26 Nov with #861 |
| asus-b460m | none | ollama (one resident model, 130 W cap), `paddock.service` (Qwen3.6 35B, #817, #822), agent `paddock`; off 21:00 to 08:30. 26 Nov: `paddock.service` stopped and the GPU at 270 W for the ladder (#838); it owes the deploys of #850 and the merges after #858 on purpose, no asus deploy on 26 Nov (pool finding 5) |

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
