# Weekly goals: 23–29 November 2026

Outcome: a working metrics → alerts → investigation → fix → verification loop, and the specialist agent roles
that run it. Small PRs, shipped by execution pool sessions, each merged batch deployed to the hosts it touches. Updated when
PRs merge. The direction this queue serves: [vision.md](vision.md).

## How we work (owner, 23 Nov)

- Iterate, do not perfect: each item is one small change that fixes a pain we have now. Only a finding that makes a
  change unsafe, or means it does not fix the problem, blocks a merge; the rest go on a follow-up list.
- One priority queue, no calendar. A topic that just merged an iteration drops behind topics that have waited
  longer, so no topic starves. An urgent break jumps the queue.
- No dedicated benchmarks. Ship behind a switch scoped to one host or worker and compare on the running system.
  Every feature that claims an improvement needs a switch, a metric that can tell on from off, and a regression alert.
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send` for each follow-up), never to Herdr
  panes. Deploy as we go; the execution pool's slots are the rollout unit.
- Night is reduced capacity, not a pause. msi and asus are off 21:00 to 08:30 and are never woken; acer (heavy work,
  one job at a time) and lenovo (edits only) keep working the queue with about two active sessions. Only work that
  needs msi or asus waits for the morning.
- Prefer upstream nixpkgs modules and built-in features over home-made services.

## Queue

Owner, 24 Nov: ship the real work with a narrow test per change; no long gate per change. Merges and deploys are
collected into a batch, and the scheduled full gate on main (acer, twice a day since Check tuning below) covers the batch.

First real task ran through the pool on 24 Nov at 11:53: a Claude task submitted with `exec-pool submit` on acer,
claimed by `pool1`, cloned, run and settled as succeeded in 12 s, slot reset.
Merged since 10:00: pool metrics, dashboard row and two alerts (#719, #721); submit, status and list (#720); runner
runs slot agents in the attempt workspace (#725); fleet dispatch listener and credential, off by default (#726, #730);
Codex and Pi in slots (#727); systemd-run no longer expands task text (#728); result and wait (#729);
`typed-interfaces-test` green again (#731); fleet credential fix (#733); heartbeats, cancel and record_result with a
300 s lease (#734, #735); msi slot and runner, so the pool runs on acer and msi (#736); a task pushes its own branch
`pool/<task id>` and reports it (#737); `exec-pool submit` from lenovo plus skills pin (#738); submit refuses an agent
no live slot offers, and acer offers pi (#739); rollback across a migration and visible slot quarantine (#740).
Since 14:25: sessions are live (#744 queue with inbox, park and send; #745 turn in a slot; deployed 15:09). The
first live session, `cli-c86629271199d5b7` on acer, parked itself after 14 s, `exec-pool send` woke it 6 s later,
and it resumed with its transcript and an uncommitted file intact. Then session housekeeping (#746: gcroots, disk
metric, remover), session metrics with tokens and cost per turn, `exec-pool sessions --gc` and a dashboard row
(#747), t1 and herman retired for a second pool slot on msi and acer, their unpushed branches bundled to
`/var/lib/worker-archive` on each host (#748), a session claimed only on a host that holds its state (#749), the
remover on, for sessions handed back whole only, final after 7 days or waiting idle 14 days (#750), and no start
limit on slot units (#751, being replaced: the slot reset clears the limit instead). skills#162: coordinator
`pool:start`, `pool:send`, `pool:wait`.
Since 16:40 (live on acer and msi at #764 unless noted): slot reset clears the start limit (#755), remover dir names
(#756), GitHub sidecar for acer slots (#757), drain before power-off with a drained one-shot going to review (#758),
a1, m1 and m2 retired for three slots on acer and four on msi, unpushed work bundled under `/var/lib/worker-archive`
(#759), the coordinator dispatches only as pool sessions (#760, #761; skills#163, #164), timers and `handed_back`
(#762, #763), msi slots reach GitHub through acer's sidecar with no key on any slot and private clones through the
proxy (#764), a timed-out turn continues up to three times (#765, merged, not deployed).
Live proofs: a timer woke a parked session at 17:59:02; a session ran turn 1 on acer and turn 2 on msi with its
state, and pushed from msi through acer's sidecar to the private skills repo; state is pushed to the acer store at
every park.

Live findings, 19:00: acer `pool1` sat quarantined 15:11 to 17:27 with no alert (only `ExecPoolQueueDown` is loaded
in Prometheus); a failed prepare leaves an empty result; slot metrics exist for acer only; the first msi deploy at
18:06 rolled back on a slot reset overlapping activation (the retry passed); lenovo cannot push nixos-config (its
devenv gate is stale and re-entering builds) nor fetch a new private skills pin as a user.

Decided by the owner, 24 Nov: the pool is re-architected around sessions that park and wake by themselves, with no
pause or resume command. A task is a session, a lease is a turn, and every turn ends in a park to waiting. A wake is a
row in the session's inbox (`exec-pool send`, or a due timer). State lives outside the slot under the workers state
dir, is docked into a slot at `/session` for one turn, and is pushed to acer at every park so any host can continue
it. The named workers are pool slots now: herman and t1 retired for pool2 by #748; a1, m1 and m2 retired for acer's
pool3 and msi's pool3 and pool4 by #759. Brief 656 (explicit pause and resume) is replaced by 1c.

Current batch, 20:32: pool metrics and alerts (#768), turn timeout (#765, #770), Shunt alerts (#771), priority and
logs (#772) and deploy drain (#773) are merged and deployed; lenovo deployed #774 at 20:32. Only asus is behind.

State at 25 Nov 02:30: interactive panes for pool sessions are live on acer (#780); msi follows after 08:30. Git-backed
session state is in flight (branch `pool/cli-fd59cf28cf1b122c`). Night: a cheaper agent drives the live checks and
merges from a runbook; the coordinator wakes on finish events and after two quiet hours.

### Pool platform: how we iterate

Owner, 24 Nov 20:40: "ensure that we iterate on this platform so that we can improve this". The list lives on
[#646](https://github.com/sammasak/nixos-config/issues/646) and here.

How we iterate: every coordinator check-in reads the live signals below, adds what it finds to this list, and starts a
pool session for the top open finding. A finding is closed by a merged PR that is deployed and seen in the signal, not
by a test.

**Signals (Prometheus, all by `host`)**: `exec_pool_slots{state}` (busy, idle, quarantined),
`exec_pool_transitions_total{reason}` (turn_timeout, turn_error, host_draining, needs_review), queue wait and wake
latency histograms, `exec_pool_session_turn_seconds`, turns per session, `exec_pool_session_cost_usd_total` and tokens,
store transfers, `shipping_deploy_lag_hours`. Alerts: the nine `ExecPool*` rules, `HostBehindMain`, `DeployRolledBack`.

**Found live on 24 Nov and fixed**: silent quarantine with no alert loaded (#768 plus the black-pi deploy), slot
metrics for acer only (#768), a turn cut at 30 minutes left its session waiting for ever (#765), a slot reset racing a
deploy's activation (#768), stale Shunt alerts for retired workers (#771), deploys waiting for an idle pool and a turn
lost when the queue restarts (#773), no claim priority (#772).

**Found live on 24/25 Nov, fixed in branch `pool/cli-bae083cc3a959222`** (deploy acer and msi): a turn that ends in an
error now gets up to three continues, due 10, 30 and 90 minutes later, each a new turn told what happened; a session
left with nothing to wake it after errors or timeouts is counted in `exec_pool_sessions_stalled{reason}` and alerts
(ExecPoolSessionStalled). `gh pr create` and `gh pr comment` failed because they use GraphQL, which the proxy refuses:
pool tasks are told the REST calls (`gh api repos/<repo>/pulls`, `.../issues/N/comments`) the proxy already passes.
The proxy fetches any other repository unsigned and read-only (truespar/scriptor). The old layout's session trees and
`.sessions-store` are removed daily when cancelled or handed back on their branch, the rest counted
(`homelab_exec_pool_legacy_sessions_kept{reason}`).

**Found live on 24/25 Nov, fixed in branch `pool/cli-3298c29ab4554a39`** (deploy acer and msi): an interactive
turn waiting on its own background command (a build started in the background) looked idle and parked after the grace,
which killed the command; a live Bash tool command of the agent in its slot's turn unit now keeps it busy, the 30 minute
limit still the outer bound. `just pool-merge-check` built exec-pool alone; it now builds each `pkgs/<dir>` the branch
changes (`pkgsDir.<dir>`) and names them, nothing when none changed, so a lint failing inside a package build (ruff
E501 last night) is caught before merge.

**25 Nov, branch `pool/cli-8ce84f45f00fc734`** (deploy acer and msi): a turn waiting only on its own background
subagent no longer looks idle: Claude writes `subagents/agent-<id>.meta.json` under the session's transcript and adds
`"finished": true` when it ends, so an unfinished one written this turn keeps the agent busy, the 30 minute limit
still the outer bound. Per merged change (epic 646): `exec-pool sessions [ID]` prints one JSON line per session with
turns, wall, running, queued, review and waiting time (split by park reason), tokens, cost and the pull request of
`pool/<task>` as gh finds it (migration 0020, view `session_summaries`). `exec-pool-session-report` on acer logs each
merged session once to the journal, and the pool dashboard's "Merged sessions (7 d)" table reads it from Loki, with no
id in a metric label. Follow-up: a runner restarted mid-turn takes its new start as the turn's, so a subagent from
before the restart is not seen.

**25 Nov, branch `pool/cli-5b06de3210ce90a1`** (deploy acer and msi for the pool, black-pi for the rules):
`exec-pool status` and `list` show each task's priority (migration 0022, additive, floor 9). A turn waiting only on a
detached job (`nohup`, `setsid`) stays busy: a process in the turn unit's cgroup that the container's init adopted,
in a session not the agent's (so Chromium's crashpad is not one), the 30 minute limit still the bound; a job started outside the unit (`systemd-run`) still dies at the park
(contract). ExecPoolSessionStalled: the metric covers a third timeout in a row (no continue left, nothing in the
inbox), and the old 10 minute `for:` plus textfile, scrape and `group_wait` paged within about 13 minutes, so the
22 minute silence was most likely the rule or collector (#783, merged 05:00) not yet live; unverified, slots reach no
Prometheus. Now `for: 5m` (about 8 minutes) and the text leads with `exec-pool send ID`. HostBehindMain: `upHours`
2 to 6, up in a row, so a host woken behind after its planned off, or one a batch deploy reaches within hours, is not
paged; an off host never matched (`up == 1`). Read the 14-day firing history once deployed. PR #797. Open: a
second session stalling on the same host and reason is the same ExecPoolSessionStalled alert, so it pages nothing new.

**25 Nov, branch `pool/cli-9e251aacbfa086ca`** (deploy lenovo): #792 merged a capped unit on lenovo and its
deploy then failed the sam.memory assertion, as nothing before merge evaluates a host toplevel (the push hook runs
`nix flake show`). `just pool-merge-check BRANCH` now evaluates every host's toplevel drvPath from the merge with
origin/main, one nix process per host (all six in one process OOMed a slot's environments.slice), about 3 min on msi
(acer-swift 63 s, msi 42 s, asus 38 s, black-pi 19 s, lenovo 15 s, naked-pi 8 s; peak 4.2 GB), then builds the
changed packages as before. lenovo's user.slice 8288M to 8032M, still above the 7782M the build-bounds test asserts
(4.6 GiB idle sessions plus the largest 3.0 GiB unit): 259M of budget left instead of 3M; a new 128M unit evaluates.
Open: the 4.6 GiB idle figure predates the named workers moving to pool slots; re-measure lenovo's user slice. PR #799.

**25 Nov, branch `pool/cli-6a8cf03c11ffa376`** (no deploy: the skills store path and every toplevel drvPath are
unchanged): the skills input is `git+ssh` like the other six private inputs (devenv-platform, factum, herman,
llm-gateway, nix-audit, rf-proto), so `just deploy` as lukas fetches a new skills pin with lukas's SSH key instead of
the root-only nix access token (the 404 after #798). Same narHash, so the same store path. Chosen over a prefetch in
the deploy recipe (more recipe code, still a github: lock) and a token group (wider secret access).
`scripts/test-deploy-recipes.py` fails on any private input in flake.lock that is not git over ssh. The 4.6 GiB
lenovo user.slice note above stays as written, not re-measured.
Open: lenovo's root rebuild trigger (`modules/homelab/nixos-rebuild-trigger`) fetched a new skills pin with the
token and now needs a GitHub SSH key for root, as it already did for the other private inputs; glance on lenovo:
`sudo ssh -T git@github.com`.

**Open, in pick-up order**

1. Session turns are headless; the owner wants the same interactive Herdr panes the named workers had, with an idle
   grace period, park, resume into a pane and `attach`: live on acer (#780), msi after 08:30.
2. Two PRs that each built alone broke main together (#765 with #768). Build the merge result of a pool crate PR
   before merging it: `just pool-merge-check BRANCH` on acer, before each merge that touches `pkgs/`.
3. Three sessions lost a turn to the 30 minute limit today. Re-check the limit once turns are interactive and park on
   idle.
4. Not yet seen live: a drain started by `just deploy`, claim order by priority, the prepare failure counter,
   `coord:brief` against the real CLI.
5. The drain starts before the build, so a long build keeps a host from claiming.
6. Slot isolation: `homelab.execPool.slot.privateUsers` booted in `execution-pool-vm` (both slots, ids, dock, GitHub
   sidecar, daemon, the toggle reset) and on for msi's slots, #796 (deploy msi, then
   acer for the per-slot fetcher cache); every slot now has its own fetcher cache, emptied by each reset. Open: acer's
   slots, one line in `hosts/acer-swift/configuration.nix` once msi has run a day with it; what still runs as host
   root for a slot is listed in `docs/nspawn-workers.md` (Execution pool).
7. `status` and `list` do not show priority.
8. `HostBehindMain` needs 24 h; black-pi lacked new alert rules for some hours unseen.
9. lenovo cannot push nixos-config (stale devenv gate); a new private skills pin fetches as a user over git+ssh
   once `pool/cli-6a8cf03c11ffa376` merges.
10. Cost: about 45 USD of session cost on 24 Nov; cost per merged PR is in `exec-pool sessions` and the dashboard
    table once `pool/cli-8ce84f45f00fc734` deploys to acer; read it after a day.
11. Store follow-ups in #754. Credential slice 3 (a slot pushes only `pool/<task id>` and `refs/pool-wip/<task id>`,
    `exec-pool-push-filter` behind `homelab.execPool.ownRefsOnly`, on for acer) on `pool/cli-3d4da7d4a57f8ba1`: deploy
    acer, see a push `passed` and one `refused`, then turn it on for msi. Slice 4 (GitHub App tokens) needs the owner to
    create the App and a sops secret for its key first.
12. Session state lives in git (#781, merged); its old trees and store are removed by the legacy remover once deployed.
13. The proxy cannot hold a pull request to the task's own repository and `pool/<task id>` branch: the head is in the
    request body, which Caddy does not read, and acer's fleet site does not know which slot asks. Today any listed
    repository, any head; a body-reading gate would close it.
14. A turn whose input never reached the agent is queued again at once, skipping the error backoff, and never counts as
    stalled (pre-existing; the runner cannot move a message's `due_at`).

### Paddock SSD-backed MoE expert streaming

Same priority as the pool platform. One dedicated pool session drives it end to end from draft
[paddock#2](https://github.com/sammasak/paddock/pull/2) (packaging: paddock#1; integration: #508; feasibility and
benchmark requirements: #776; epic: #491).

- Paddock before Strata.
- Isolated behind a narrow abstraction, the existing fast path kept, fork maintenance kept small.
- Decisions, progress, acceptance criteria and follow-ups live in those issues and PRs.
- Small reviewed changes with measured results on asus (asus is off 21:00 to 08:30).
- 25 Nov 02:30: steps 1 to 4 done on the CPU side in draft [paddock#3](https://github.com/sammasak/paddock/pull/3);
  the first asus runs follow after 08:30, per the run list on #508.
- Aim: a polished upstream contribution.

### Waiting, in pick-up order

| # | Topic | Pain now | Next small change |
|---|-------|----------|-------------------|
| 1 | Pool platform | the open findings above | a pool session for the top open finding |
| 2 | Deploy | asus behind main | asus in its power window |
| 3 | Alerts | 624-l names a command in every kept alert and cuts 11 rules that guard nothing | merge 624-l, deploy black-pi, read the next 14-day firing list |
| 4 | Gates | scheduled gate red since 24 Nov on `checks.x86_64-linux.execution-pool-vm`, which failed to evaluate (slots' repos need `sam.workers.ghHostsFile`, the VM set none); fixed in branch `pool/cli-38a64f8b5b1d81f5` | merge, deploy acer (scheduled gate) and black-pi (rules), read the next scheduled gate result |
| 5 | Live comparison | `ShuntCollectorStale` fires since the on side moved | read a day of Shunt on and off on 25 Nov, now on acer `pool1` |
| 5b | Live comparison | #626 had no per-variant tokens, cost or compactions from the pool | deploy branch `pool/cli-950c25fbd3f89b7a` (acer, msi, black-pi), then read the "Compaction window on versus off" table a day later |
| 6 | Leftovers | one draft open | #616 (needs a physical reboot of black-pi) |

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

## Priorities

| P | Issue | Scope | State |
|---|-------|-------|-------|
| P0 | [#600](https://github.com/sammasak/nixos-config/issues/600) | Self-improvement milestone | all hosts on main of 23 Nov; first live receipts on #624 and #625 (24 Nov) |
| P0 | [#624](https://github.com/sammasak/nixos-config/issues/624) | Actionable alerts | split below |
| P0 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt metrics, Grafana, alerts | split below |
| P1 | [skills#138](https://github.com/sammasak/skills/issues/138) | Thin global context, role context | merged, skills#141 |
| P1 | [skills#130](https://github.com/sammasak/skills/issues/130) | Write-capable role contracts | merged, skills#142 |
| P1 | [skills#139](https://github.com/sammasak/skills/issues/139) | Metrics analyst | merged, skills#143, #144 |
| P1 | [skills#131](https://github.com/sammasak/skills/issues/131) | Incident investigator | merged, skills#145 |
| P1 | [skills#140](https://github.com/sammasak/skills/issues/140) | Improvement verifier | merged, skills#146, #148 |
| P1 | [skills#137](https://github.com/sammasak/skills/issues/137) | Observability engineer | merged, skills#147; follow-up waits for a pool session (m2 retired) |
| P1 | [skills#133](https://github.com/sammasak/skills/issues/133) | Nix platform engineer | merged, skills#149 |
| P1 | [skills#136](https://github.com/sammasak/skills/issues/136) | Dynamic handoffs pilot | closed 24 Nov: live named-role spawn and tests green |
| P2 | skills [#132](https://github.com/sammasak/skills/issues/132), [#134](https://github.com/sammasak/skills/issues/134), [#135](https://github.com/sammasak/skills/issues/135) | Remaining specialists | all merged: skills#153, #154, #155 |
| P1 | [#646](https://github.com/sammasak/nixos-config/issues/646) | Execution pool, v0.1 | split below; never ahead of a P0 item |
| P1 | [paddock#2](https://github.com/sammasak/paddock/pull/2) | Paddock SSD-backed MoE expert streaming | one dedicated pool session; see the queue above |
| P2 | [#626](https://github.com/sammasak/nixos-config/issues/626) | Auto-compaction, live on/off | 300K on acer `pool2` only, branch `pool/cli-950c25fbd3f89b7a`; needs acer and msi (runner, migration 21), rules and dashboard on black-pi; read one day after deploy |

## Work items

### #624 actionable alerts

| Item | What | State | PR |
|------|------|-------|----|
| 624-a | Inventory: signal → rule → route → last receipt → gap | merged | #629 |
| 624-b | Annotation contract (summary, description, query, runbook), asserted by a check | merged, deployed | #632, #636 |
| 624-c | OTLP relay rejection alert (the monitoring-blindness example) | merged, live on black-pi; no rejected write seen live yet | #659 |
| 624-d | Journal-delivery stale alert | merged, live on black-pi | #640 |
| 624-e | Backup stale, never recorded, collector stale | merged, live on black-pi; first recorded runs due 24 Nov 03:00 | #640 |
| 624-f | Synthetic fire and resolve test through Alertmanager and alert-bridge | merged | #666 |
| 624-g | Live delivery receipts | read 24 Nov (comment on #624): NodeOOMKill and the synthetic alert reached ntfy and resolved; no blindness alert has fired yet | |
| 624-h | Query and runbook in the ntfy page | merged, live: Alertmanager posts straight to ntfy, alert-bridge removed | #672, #680 |
| 624-i | Alerts red with nothing to do (25 Nov): DeployRolledBack per host until a good deploy of it; EscapeFound drops a reapplied revert (the live one, `78f4ee80`, reapplied as `ab8acd36`), one marked `Escape: no` and closed escape issues; the scheduled gate retries a red head once; RetroDueStepFailsRepeat clears on a scheduled green after the last failure; each text names its command | branch `pool/cli-273036d46c7d3230`; needs lenovo (collector) and acer (scheduled gate), rules on black-pi | |
| 624-j | Audit and cut (25 Nov, #600 comment): 16 rules deleted that could not fire here (RAID, bonding, scrape limits, Alertmanager cluster), could reach no one (Prometheus not connected to Alertmanager; lenovo's watchdog covers it) or duplicated a page (TargetsMostlyDown, HealthScoreLow, the some-Alertmanagers twin), plus the never-notifying NodeCPUHighUsage, InfoInhibitor and NodeSensorNearCritical; UnitOOMKilled inhibits NodeOOMKill on the same node; TargetDown has its own runbook and query text; five host texts name their command. HostExpectedOff was already a silent inhibitor (route test added). The 14-day firing history is unknown from a slot | branch `pool/cli-f7637116415e4bb0`; deploy black-pi | |
| 624-k | Alert to investigation with no human in between: an alert switched on in `homelab.alertInvestigations.alerts` (lenovo: `NodeSystemdUnitFailed` alone) that fired 15 minutes with none open starts one read-only incident-investigator pool session per firing (at most 3 a day per name), its prompt holding what lenovo read (alerts, Prometheus, the unit's journal); its report lands on the issue `Alert: <name>` (label `alert-investigation`, one per name). `homelab_alert_investigations_total{alertname,outcome}`, failures by reason; `AlertInvestigationFailed`, `AlertInvestigationsStale`. Read-only by prompt: the proxy cannot refuse a slot's push (item 13 of the pool list), so a pushed `pool/<id>` fails the investigation | branch `pool/cli-f7ad8047dbbfdc72`; needs lenovo (trigger), rules on black-pi | #792 |
| 624-l | Finish the clean-up (25 Nov, from the coordinator's 14-day firing list): every kept alert's text names its command or dashboard (the upstream node, Prometheus and Alertmanager ones, the shipping KPIs, the llm-gateway one, ShuntDelegationFailing, ShuntSilent, ClaudeCompactionLoop, and the rest a review named); 11 unfired rules that guard nothing cut (NodeFileDescriptorLimit x2, NodeClockSkewDetected, NodeMemoryMajorPagesFaults, NodeDiskIOSaturation, the notification queue, duplicate and out-of-order timestamps, target sync, high query load, LLMGatewayBatchHittingReserve); the keep or delete list per unfired rule is in the PR body | branch `pool/cli-7071e0038fcbe527`; rules on black-pi | |

Open for #624, in pick-up order: after 624-k deploys, read the first live investigation on its issue and its counters; after 624-i deploys, read the live list and confirm each alert cleared or names
its command; the failing check behind the live ScheduledGateRed and RetroDueStepFailsRepeat was
`checks.x86_64-linux.execution-pool-vm` failing to evaluate, which wrote no check record (branch
`pool/cli-38a64f8b5b1d81f5`: the VM fixed, an eval failure now records its check, the red series carries `check`, and
both alerts name one rerun command, `nix build -L .#<check>` or `NIXOS_STEP=<step> devenv tasks run nixos:step`); an intentional revert that is never reapplied still counts for 24 h (no after-the-fact
acknowledgement); after 624-l deploys to black-pi, read the live rule list and the next 14-day firing list; the rules younger than 14 days (exec-pool, alert-investigations, ShuntHookOverhead, ExecPoolCompactionWindowCostlier) were kept untested by that window, so judge them on the next one.

### #625 Shunt metrics

| Item | What | State | PR |
|------|------|-------|----|
| 625-a | Read-only check of the hook JSONL on lenovo, schema decision | done: comment on #625 | |
| 625-1 | Collector, fixture tests, NixOS wiring (nav-metrics pattern) | merged, enabled on no host yet | #638 |
| 625-2 | Shunt section in the agent-harness dashboard, stale and failing alerts, collector on lenovo | merged, live: collector on lenovo, rules on black-pi | #644 |
| 625-pilot | On/off on the running system (no benchmark, owner 23 Nov) | merged, live: on for lenovo and acer's `pool1` (moved from `a1` by #759), off for acer's other slots; read a day on 25 Nov | #678, #679 |
| 625-3 | Hook overhead: `shunt_hook_time_ms{hook}` with validate-bash as the off side's control, ms per Bash call on and off (dashboard panel), `ShuntHookOverhead` (over 250 ms per call, at least 50 calls, a starting bound) | branch `pool/cli-273036d46c7d3230`; needs lenovo and acer, rules on black-pi; set the bound from the first day's reading | |

### #646 execution pool (v0.1)

Nix declares slots; a separate runtime owns queue, leases and task state; workers, Herdr and the CLIs stay as they
are. v0.2 and v0.3 stay locked until the v0.1 offline gate has evidence. Deferred items: the checklist comment on #646.

| Item | What | Needs | State | PR |
|------|------|-------|-------|----|
| [#649](https://github.com/sammasak/nixos-config/issues/649) | Contract: ADR, `pkgs/exec-pool` types and state machine, compatibility fixture | | merged; acer gate 23 min, one review round plus a fix round, about 4 h from dispatch to merge | #667 |
| [#650](https://github.com/sammasak/nixos-config/issues/650) | `sam.workers.executionPool` slot count | #649 | closed; `pool1` declared on acer | #704, #716 |
| [#651](https://github.com/sammasak/nixos-config/issues/651) | PostgreSQL queue, leases, fencing | #649 | closed; live on acer | #673, #693 |
| [#658](https://github.com/sammasak/nixos-config/issues/658) | Events to the journal, textfile metrics, dashboard row, two alerts | starts with #651 | first slice merged, live on acer: metrics, dashboard row, two alerts | #719, #721 |
| [#652](https://github.com/sammasak/nixos-config/issues/652) | Runner: dispatcher, slot control, guest executor | #650, #651 | live on acer: first Claude task succeeded 24 Nov; heartbeats, cancel, record_result, own branch per task and submit refusal merged | #711, #713, #720, #725, #728, #729, #734, #735, #737, #738, #739, #740 |
| [#653](https://github.com/sammasak/nixos-config/issues/653) | Per-attempt isolation and egress | #652 | merged, live: each attempt runs in its own workspace; Codex and Pi routes in slots | #717, #725, #727 |
| [#654](https://github.com/sammasak/nixos-config/issues/654) | Fleet dispatch: msi runner against acer's queue | #652 | merged, live: the pool runs on acer and msi | #726, #730, #733, #736 |
| Sessions | Park and wake re-architecture (queue above); replaces brief 656 | #652 | live on acer and msi: first session parked, woke and resumed 24 Nov; store on acer, drain, timers, sidecar and pool-only coordinator live at #764; #765 merged | #744 to #752, #755 to #765 |
| v0.1 gate | Acceptance script in a VM: PASS, FAIL or UNTESTED per criterion | #653, #658 | | |

Per merged pool PR, record here: gate minutes, review rounds, hours from dispatch to merge.

## Workers

Placement order: acer, then msi, asus last (it carries ollama and the heavier loads).

| Host | Worker | Item |
|------|--------|------|
| acer-swift | `pool1` to `pool3` | pool slots, Shunt on for `pool1`, a 300K compaction window for `pool2` (#626, once deployed); `herman` and `a1` retired, their work in `/var/lib/worker-archive` |
| msi-ms7758 | `pool1` to `pool4` | pool slots; `t1`, `m1` and `m2` retired, their work in `/var/lib/worker-archive` |
| asus-b460m | none | `a624`, `s138`, `s130` retired |

No slot holds a GitHub key: acer's and msi's slots push through acer's GitHub sidecar, private clones go through the
proxy, and the owner merges the PRs.

## Deploys

Every host deployed main on 23 Nov: acer-swift, msi-ms7758, asus-b460m, black-pi, lenovo. The first black-pi deploy
rolled back on a journal-metrics start race, fixed by #634. asus deployed again after #639 (workers retired).
msi, asus and acer deployed main again on the evening of 23 Nov (gaming entries, skills pin #661; acer also has the
pin from #670). lenovo and acer deployed #699 at 06:40 on 24 Nov, black-pi #694 at 05:00. On 24 Nov: asus #703 at 08:25, msi #714 at 10:00, acer #710 at 09:50 and #728 at 11:50 (the #725 deploy rolled back first: fixed by #728); acer and msi at #739, then #745 at 15:09 (sessions live), then #750 at 16:34 (acer) and 16:36 (msi), then #764 (the first msi deploy at 18:06 rolled back on a slot reset overlapping activation; the retry passed). Lenovo's user slice (8.1G) hit its memory cap while two agents ran skills gates there: one at a time.

## Gaming entries (owner request, 23 Nov)

asus: desktop, Steam, Sunshine streaming. msi: desktop and Steam, no Sunshine and no inbound ports. In the entry the
21:00 power-off does not run and inference is not started. Booted on neither host yet; the owner accepted it untested.
Steam Remote Play can still stream from msi through Valve's relay: the switch is in the Steam client.

## Owner gates

None, except physical access and spending money (owner, 23 Nov). The coordinator decides and ships everything else.
The scheduled gate on acer runs the full gate on main; nothing is owed by hand.

## Merged this week

- nixos-config: #629 alert inventory, #630 asus workers, #632 and #636 annotation contract, #633 acer and msi slots,
  #634 journal-metrics wants alloy, #635 Claude sessions keep a working shell across a deploy, #638 Shunt collector, #639 asus workers retired,
  #640 backup and journal alerts, #643 and #661 skills pins, #644 Shunt dashboard and alerts, #659 OTLP rejection alert,
  #662 and #665 asus gaming entry with Sunshine, #668 msi gaming entry without streaming,
  #669 Steam in both entries and no scheduled power-off while gaming, #666 synthetic fire and resolve test,
  #667 execution pool contract, #670 skills pin, #671 priority queue, #672 runbook link and query in the
  notification, #673 pool queue, #675 pool CLI and metrics, #676 night mode, #678 and #679 Shunt on for a1 with
  on/off labels, #680 Alertmanager posts to ntfy and alert-bridge removed, #682 compaction window per worker,
  #683 one eval per host in the flake check, #684 and #685 Loki ruler, #686 on versus off row, #687 repeat-failure
  alert clears, #642 typed textfile port, #637 usage records, #631 asus model capability, #689 late-failure guard,
  #690 seventh-host reuses evaluations, #691 role adapters pinned to the skills input, #693 pool queue on acer,
  #694 and #695 flake check green again, #697 guest records shipped by the host only, #698 night eval step,
  #699 skills pin, #701 untouched issues alert, #702 compaction loop alert, #703 skills pin, #704 pool slots,
  #705 record backlog alert, #707 and #712 scheduled gate, #708 PostgreSQL module, #709 guest daemon OOM order,
  #710 annotation check on vendor rules, #711 agent adapter, #714 guest DNS, #716 slot agents, #717 attempt workspace,
  #719 and #721 pool metrics and alerts, #720 submit CLI, #722 inventory with one slot, #724 skills pin,
  #725 runner in the attempt workspace, #726 and #730 fleet dispatch listener and credential, #727 Codex and Pi in slots,
  #728 no expansion of task text, #729 result and wait, #731 typed interfaces green,
  #733 fleet credential fix, #734 heartbeats, cancel and record_result, #735 exec-pool cancel, #736 msi slot and runner,
  #737 task pushes its own branch, #738 submit from lenovo and skills pin, #739 submit refuses an agent no slot offers,
  #740 rollback across a migration and slot quarantine, #744 session queue, inbox, park and send, #745 session turn
  in a slot, #746 session housekeeping, #747 session metrics and `sessions --gc`, #748 t1 and herman retired for
  pool2, #749 claim only where the state is, #750 session remover on, #751 no start limit on slot units, #752 session state in the acer store,
  #755 slot reset clears the start limit, #756 remover dir names, #757 GitHub sidecar for acer slots, #758 drain before
  power-off, #759 a1, m1 and m2 retired for slots, #760 and #761 coordinator dispatches as pool sessions, #762 and #763
  timers and `handed_back`, #764 msi slots through acer's sidecar, #765 a timed-out turn continues
- skills: #141 role context (#138), #142 execution field (#130), #143 and #144 metrics analyst (#139),
  #145 incident investigator (#131), #146 improvement verifier (#140), #147 observability engineer (#137), #148 verifier follow-up,
  #149 nix platform engineer (#133), #151 and #152 handoffs pilot (#136), #153 nix exposure auditor (#132),
  #154 regression engineer (#134), #155 Rust maintainer (#135), #156 dangling pointer check,
  #157, #158 and #159 adapters name one place, #160 operator runbook line, #106 NUL in the bash hook, #162 coordinator `pool:start`, `pool:send`, `pool:wait`,
  #163 and #164 pool-aware idle check, sessions in `work:status` and `coord:brief`
