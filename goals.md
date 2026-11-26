# Goals: one priority queue

The direction this queue serves: [vision.md](vision.md), its four parts: (1) a platform, (2) an agent runtime
trusted with long work, (3) a system that tells us whether it got better, (4) local inference that earns its place.
Realigned on 26 Nov 2026 at 23:00 UTC against vision.md and the open and recently updated issues and pull requests
in sammasak/nixos-config, herman, skills, devenv-platform and paddock (gh, read 22:45 to 23:00 UTC). A fact marked
"per coordinator" is from the coordinator's session at 26 Nov 23:45 CET and is not on GitHub. What shipped before
26 Nov 20:00 UTC is in git history and the closed issues.

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
- "40 min build time is crazy": a gate that long is a defect to fix (Check tuning's follow-ups), not a cost to accept.
- "anytime a worker builds something it should be put into the cache".
- Work is dispatched as pool sessions (`exec-pool start`, then `exec-pool send`), never to Herdr panes. The one
  exception is the agent `paddock` on asus, which needs the GPU.
- Review is sized by risk (skills#175): only credentials, the pool runner, firewall rules and listeners get the
  orchestrated review. The coordinator merges on an independent 9/10 review and a green narrow gate (skills#173).
- Capacity follows the hosts that are up: msi and asus are off 21:00 to 08:30 and are never woken; acer and lenovo
  keep working the queue at night.
- Prefer upstream nixpkgs modules and built-in features over home-made services.
- 26 Nov: pull requests ship on the session's narrow check on its own head, the in-session independent review and a
  textually clean merge; nobody re-runs a merge check on current main. The scheduled gate on acer, three runs a day,
  is the backstop, and a clash between two clean merges costs one fix-forward pull request.
- Paddock (26 Nov, #874): "Ensure that we track this work and that we harden and fix the implementation once we are happy with it and start using this for real in our setup. Once we have find the right model fit and run pi-agents to get real feedback and metrics we can then continue to harden it and eventually do a upstream contribution. Also since we are doing this we need to keep in mind that other contributions are going to the main thing and not to our fork so we need to keep our branches up to date. Also some of work might already be fit for upstream (nix? - what metrics do we need here before we are happy with upstreaming it?)"
- Paddock upstream work runs as two tracks on the fork (owner, 26 Nov): track 1, Nix support then plain devenv
  (paddock#32, "NOT OUR DEVENV-PLATFORM since this isnt ours!"); track 2, MoE served from SSD (paddock#33). Every
  fork PR is reviewed by the rubric in paddock#22. Nothing is opened on truespar/paddock.

## What "more work done" means

Tracked by [#806](https://github.com/sammasak/nixos-config/issues/806). Readings are from 25 Nov (GitHub search
answers nothing through the pool's proxy, so 26 Nov is not read here).

| Measure | Last reading |
|---|---|
| Merged pool changes per day, by agent and model | 25 Nov: 44 merged, Claude 41, Pi on `homelab/local` 3 (read 20:15 UTC) |
| Cost per merged pool change | 25 Nov: mean 1.23 USD, median 1.05 USD over 41 priced (the 3 Pi tasks report no cost) |
| Local share: local-model tasks merged with no hosted model writing the code | 3 of 44 on 25 Nov |
| Pull requests merged, all repositories, 7 d (`shipping_prs_merged`) | 254 (25 Nov 12:10 UTC) |
| Lead time, dispatch to merge | p50 0.47 h, p90 4.6 h (25 Nov 12:10 UTC) |

## Queue, in pick-up order

State of 26 Nov 23:00 UTC. The order: pool breakages found tonight first (they cost every slot now), then the gate's
first test, then the oldest waiting item, then the topics that merged most today (pool runtime, Paddock) behind them.
A brief number is the coordinator's, not on GitHub.

| # | Issue or PR | Outcome | Serves (vision.md) |
|---|-------------|---------|--------------------|
| 1 | PR [#950](https://github.com/sammasak/nixos-config/pull/950), brief 236 | a one-shot task's `gh` reaches the signing proxy, so it stops getting 401 while sessions work | 2, sandboxes with no credentials |
| 2 | brief 237 (per coordinator, no PR yet) | a host drain stops waiting without bound on a running one-shot task, so a deploy or power-off goes ahead | 2, work stops for a deploy or power-off |
| 3 | [#825](https://github.com/sammasak/nixos-config/issues/825) | the next scheduled gate on main is green on the five steps red at 18:20 UTC (fixes #931, #936, #938, #939, #942, #947); a red `qa-push-test` or `nixos-flake-check` goes back to the efficiency-plan session | 3, no long test rituals |
| 4 | herman [#62](https://github.com/sammasak/herman/issues/62), herman PR [90](https://github.com/sammasak/herman/pull/90) (sent back at 7/10) | an unmarked amendment no longer resolves on a marked sibling's citation, cross-date and cross-family shapes included, with a red control for cross-date | 2, protection against starvation: the oldest runnable item (13 Nov) |
| 5 | briefs 235 then 232 (per coordinator), after #944 and #948 | a due `waiting_until` session is woken by the idle loop's reconcile too, not only by a running turn's heartbeat (three idle reconciles missed one) | 2, a session that waits continues where it left off |
| 6 | PR [#940](https://github.com/sammasak/nixos-config/pull/940) (graded 8/10, being fixed) | each turn's result lists its subagent calls, so an in-session review can be checked after the session is gone (#901) | 3, agent runs are queryable |
| 7 | none yet (per coordinator) | the `session_summaries` view reads unknown, not 0 USD, for a session with no priced turn (the follow-up to #913) | 3, where money went |
| 8 | paddock [#26](https://github.com/sammasak/paddock/issues/26) (T2-1, track [#33](https://github.com/sammasak/paddock/issues/33)), brief 230 | expert slots described by layout (moe-ssd-1) on a branch from upstream main, passing rubric #22 | 4, MoE from SSD, fit for upstream |
| 9 | brief 229 (per coordinator) | the qwen35 long-prompt fix alone on a branch from upstream main, an upstream candidate under rubric #22 | 4, fit for upstream |
| 10 | paddock [#23](https://github.com/sammasak/paddock/issues/23) (T1-1, track [#32](https://github.com/sammasak/paddock/issues/32)) | flake packages on a branch from upstream main, built on acer with hashes matching asus's, the CUDA pack rebuilt bit-identical | 4, fit for upstream |
| 11 | [#874](https://github.com/sammasak/nixos-config/issues/874) phase C, [#807](https://github.com/sammasak/nixos-config/issues/807) | Paddock serves real Pi work on asus: the GPU repro, baseline runs, the over-window repro through Pi (paddock PR 21), then 20 local-lane tasks at a local share of 50 percent or more | 4, local models useful to the fleet's agents |
| 12 | [#903](https://github.com/sammasak/nixos-config/issues/903), [#827](https://github.com/sammasak/nixos-config/issues/827) | memory pressure lands on the slot that grows, not on the shared 9 GiB slice; the kills per busy hour on acer fall | 2, long work survives |
| 13 | [#14](https://github.com/sammasak/nixos-config/issues/14) | AdGuard's scoped DNS ports (#878) answer a tailnet query and refuse one from outside; then close it | 1, DNS stays up; the oldest open issue (3 Oct) |
| 14 | [#835](https://github.com/sammasak/nixos-config/issues/835), draft PR [#918](https://github.com/sammasak/nixos-config/pull/918) | the flake check's per-output evaluations in fewer processes within acer's memory budget (deploy pairs alone, the rest through nix-eval-jobs), or the follow-up dropped | 3, no long test rituals |
| 15 | [#625](https://github.com/sammasak/nixos-config/issues/625) | Shunt kept or removed on acer pool1 from its per-arm cost and turn series | 3, judged on the running system |
| 16 | [#624](https://github.com/sammasak/nixos-config/issues/624), [#826](https://github.com/sammasak/nixos-config/issues/826) | each firing alert has a receipt with its cause; RetroDueStepFailsRepeat clears once the scheduled gate passes `scorecard-test` (#942) | 3, alerts are few and say what to do |
| 17 | [#837](https://github.com/sammasak/nixos-config/issues/837) | nixos:qa runs `scripts/check-tuning.py`, so Check tuning's minutes come from the records, not from PR bodies | 3, where time went |
| 18 | [#898](https://github.com/sammasak/nixos-config/issues/898) | a slot's eval and fetch caches survive turns (resets shipped in #910); close it or name what is left | 2, long work on any slot |

### Anti-starvation

- herman#62 (13 Nov 20:58) is the oldest runnable item and sits at 4, ahead of the pool and Paddock topics that
  merged most today.
- [#14](https://github.com/sammasak/nixos-config/issues/14) (3 Oct) is the oldest open issue; its change shipped in
  #878 and only its two checks remain (13).
- llm-gateway [#69](https://github.com/sammasak/llm-gateway/issues/69) (23 Oct) is blocked (not now);
  skills [#104](https://github.com/sammasak/skills/issues/104) and [#128](https://github.com/sammasak/skills/issues/128)
  have their changes merged (skills #172, #175) and close once a slot's review uses the shipped prompts;
  devenv-platform [#129](https://github.com/sammasak/devenv-platform/issues/129) (13 Nov) has its step A merged
  (devenv-platform PR 167).
- pi-harness [#26](https://github.com/sammasak/pi-harness/issues/26) (now readable over REST) can close: its pin is
  already devenv-platform main 358f2c28.

### Not now (serves no vision.md goal yet, or no agent can do it)

- skills PR [169](https://github.com/sammasak/skills/pull/169): a draft the owner asked to keep unmerged until they
  approve it (review in skills#170).
- [#653](https://github.com/sammasak/nixos-config/issues/653) slice 4: per-task tokens need a GitHub App and its key, an account-level credential.
- [#645](https://github.com/sammasak/nixos-config/issues/645): booting the gaming entry on asus is physical, at the machine and the TV; accepted untested.
- [#601](https://github.com/sammasak/nixos-config/issues/601), draft PR [#616](https://github.com/sammasak/nixos-config/pull/616): the kernel fix needs a physical reboot of black-pi.
- [#474](https://github.com/sammasak/nixos-config/issues/474): naked-pi needs the issue's copy step before its next deploy; no deploy of it is queued.
- Pi in msi slots: msi as a recipient of `claude/*.yaml` and in the `gateway-api` listener's `from` is a secrets change.
- [#834](https://github.com/sammasak/nixos-config/issues/834), skills [#167](https://github.com/sammasak/skills/issues/167), [#168](https://github.com/sammasak/skills/issues/168): Shunt pilots for Codex and Pi; only after 15 decides Shunt.
- llm-gateway [#69](https://github.com/sammasak/llm-gateway/issues/69): request id in a header, blocked.
- skills [#176](https://github.com/sammasak/skills/issues/176): the owner-only list differs between the global context and the coordinator role; a wording fix with no runtime effect.
- devenv-platform [#155](https://github.com/sammasak/devenv-platform/issues/155): its change merged as PR 168; close after a Loki reading shows no text fields.
- devenv-platform [#141](https://github.com/sammasak/devenv-platform/issues/141): git-hooks follow-ups; no pain seen since PR 170.
- herman is parked for the platform sprint: #1, #3, #7, #9, #10, #11, #14, #15, #21, #22, #25, #27, #29, #30, #85 and #88.
- [#626](https://github.com/sammasak/nixos-config/issues/626): the 300K window was rejected (#875); open only until a slot sets a window again.
- [#859](https://github.com/sammasak/nixos-config/issues/859): `--requires` shipped (#886, #892, skills 178); close it.

## Open pool findings (epic #646)

Each has its queue entry; the rest of 26 Nov's findings shipped (#866, #883, #886, #892, #914, #930) and are in
git history.

1. One-shot tasks get 401 from `gh` while sessions work: queue 1 (PR #950).
2. A host drain waits without bound on a one-shot task: queue 2.
3. A due `waiting_until` timer was not woken by three idle-loop reconciles: queue 5. The running-turn case shipped in
   #944 and #948 (a heartbeat reconciles every 10 s).
4. `session_summaries` shows 0 cost for a session with no priced turn: queue 7.
5. An acer deploy build beside four busy slots caused four memory kills (per coordinator), so acer deploys are
   batched at night, at about 02:30 and 07:30 CET, when slots are fewest: queue 12 and Owed deploys.
6. PR #916's 120 s self-continue after a first memory kill worked live at 23:07 CET (per coordinator); nothing to do.
7. A deploy of asus restarts `paddock.service` and resets the GPU power limit, so no asus deploy while the agent
   `paddock` measures.
8. Sessions can finish with no pull request; the brief footer asks for it, and the signal is a finished session
   whose branch has no PR.
9. The v0.1 acceptance script in a VM (PASS, FAIL or UNTESTED per criterion) is not written.

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
No lane task is prepared: herman#57, herman#76 and factum#61 have all closed, so the next ones are picked under
#807 when asus serves a local model again (queue 11).

## Shipped since 26 Nov 20:00 UTC (PR #945's state)

- Scheduled gate reds of 18:20 UTC, each fixed on main: #936 (lock records' max age, `qa-push-test` under the gate
  environment), #938 (local-lane records get a 336 h max age, `measurement-test`), #939 (`codex-egress-test` reads
  every slot the proxy serves, not three), #942 (scorecard: a bare quoted name is a non-use), #947
  (`test-fleet-contract`'s port scan skips rule tests' series labels); #931 had fixed the E501 before.
- #937: panel texts name unknown rescue and partial collector data.
- #941: `lint-fleet-pairs` scans listener address:port pairs in the lints lane.
- #943: the push filter passes acer's refusal on, and the fleet's PR budget scales by slots.
- #913: a turn with tokens and no cost growth is unpriced, not free.
- #920: `pool-merge-check` runs `ollama-gpu-test` for asus and Ollama changes (closes the escape row it named).
- #944 and #948: a running turn reconciles at every heartbeat, so a due `waiting_until` session is queued; #948 adds
  the Pg-backed test through `Runner::tick` (brief 235 per coordinator).
- #949 (with #946's commit): asus switches its RGB lights off before poweroff (`rgb-off` unit, i2c, OpenRGB udev);
  not on asus yet.
- #945: the 20:00 UTC queue update.
- paddock PR 21, into asus/biggest-moe: over-window prompts fail with the standard `context_length_exceeded` 400.
  Fork PRs 1 to 21 are labelled by track; issues #22 to #33 define the rubric and the two tracks.
- Before 20:00 UTC on 26 Nov (#930 to #935 and earlier): see git history.

## Check tuning

Owner, 25 Nov: "keep count of how we can fine tune testing so that we can have some small and fast checks applied and
only run long gates even less often". Per-step seconds sit in Loki's `{job="platform",kind="gate-step"}` records
(`gate="nixos-qa"` or `gate="pool-merge-check"`); #849 reads this table's minutes from them. "Caught" means a fix
commit or pull request names the check as what failed.

The full gate runs only as the scheduled gate (acer, three runs a day, when main moved) or `just full-gate`.
Owner, 26 Nov: a pull request ships on its session's narrow check on its own head and a textually clean merge; nobody
re-runs a merge check on current main, and the scheduled gate is the backstop for two that merge cleanly but break
each other. `just pool-merge-check` stays for a session that wants it; it picks its checks from the changed paths
(`scripts/pool_merge_check.py`; docs: nothing) and writes one gate-step record per check.

The scheduled gate of 26 Nov 18:20 UTC (head `e43db56a`, red in 2330 s) ran every step for the first time (#912) and
was red on five: `nixos-flake-check`, `measurement-test`, `qa-push-test`, `codex-egress-test` and `scorecard-test`
(#825, #835). All five have a fix on main (Shipped); the next scheduled run is their first test (queue 3).

Checks recorded in the pull request bodies merged since 20:00 UTC: #936 `qa-push-test` 362 s and its sibling tests
under 20 s each, caught the two gate reds it fixes; #939 `codex-egress-test` 68.8 s and `test-scorecard.py` 6.8 min,
caught the three-slot assertion; #941 `lint-fleet-pairs.py` under 2 s, `test-qa-push.py` about 3 min and the pre-push
hook 551 s, caught nothing (`test-fleet-contract.py` was OOM-killed in the slot after 187 s); #942 the scorecard build
about 1 min and `test-scorecard.py` about 1.5 min, caught nothing; #943 the push-filter build 4.9 min, its test 0.9
min and workers-eval's GitHub forward 4.7 min, caught nothing; #944 `nix build .#exec-pool` 6 min; #948 `nix build
.#exec-pool` 14 min 7 s, its new test red without the change, as meant; #947 `test-fleet-contract.py` 11.5 min on
acer at night beside a flake-show (54 pass); #920 `test-pool-merge-check.py` 16 s; #949 an evaluation of the rgb-off
unit 3 min 38 s, the asus toplevel build owed. No body names a failure that no check caught, so no escape row is added.

| Check or step | Typical minutes | Real defects caught (commit or PR) | Depends on |
|---|---|---|---|
| Whole scheduled gate | 26.0 mean over 7 runs to 26 Nov 03:20, 90.1 worst; 38.8 on 26 Nov 18:20 UTC (every step, 5 red); "40 min build time is crazy" | 6 reds before 26 Nov 18:20 (#759, #795, #814, #828, #855, #885), then the five above | everything |
| lint-comments, lint-shell, deploy-rs-pins | seconds (7, 3 and 0 s on 26 Nov 18:20) | lint-comments 9d7cec2a (#800); shellcheck d947c2a2 (#795) | `.nix`, `.sh`, `.py`; `scripts/*.sh`; devenv and flake locks |
| fmt-check | 10 s on 26 Nov 18:20 | 747a1f71 (#684) | every `.nix` |
| secrets-verify | 0 s in records | none traced | `secrets/` |
| nixos-push-eval (`nix flake show`) | 2.3 mean over 264 (7 d; 3.9 GiB, acer); 1.5 to 5.5 on 26 Nov | 24cb9892 (#797) | every flake output's attribute set |
| gate probe | 4.2 mean over 90 (7 d); 8.5 on 26 Nov 07:07 UTC | none traced | every host |
| nixos-flake-check | 14.7 mean over 91, 64.6 worst (7 d); 46.0 on 26 Nov 07:07 UTC | `execution-pool-vm` (#795); ruff E501 (#787, #931); exec-pool clippy and rustfmt; `legacyPackages` (#828); a failed output listing (#856) | every check and every x86 host |
| workers-eval-test | 2.1 mean (7 d); 6.2 on 26 Nov 07:07 UTC | 0b90b42d (#781), f4fac5f5 (#736); the catch-all 403 ordered first (#914) | gate probe, `modules/workers/` |
| seventh-host-test | 3.2 mean (7 d) | the AdGuard anchor (#885) | hosts.nix, fleet.nix, every host |
| test-fleet-contract | 11.5 on acer at night beside a flake-show (#947, 54 pass) | the rule tests' series labels (#947) | the probe, `modules/core/fleet.nix` |
| scorecard-test | 1.5 to 6.8 (#939, #942) | the bare `"factum"` read as unknown (#942) | `pkgs/scorecard/`, module sources |
| `nix build .#exec-pool` | 6 to 14 (#944 6, #892 12.9, #948 14.1) | `tests/queue.rs` (#935) | `pkgs/exec-pool/` |
| shunt-metrics-test | 0.1 (7 s mean over 28) | df0f5007 (#759) | probe, `scripts/shunt-metrics.py` |
| ollama-gpu-test | 0.03 (2 s; 16 s on #855's branch) | asus's MemoryMax (#855); `pool-merge-check` runs it for asus since #920 | `hosts/asus-b460m/`, the ollama module |
| deploy-recipes-test | 0.03 (1.9 s mean) | fails on a `github:` private input since #803; the installed `exec-pool-drain` (#863) | Justfile, flake.lock |
| The other tests in `tests` (devenv.nix) | 3.8 summed over 45 steps; qa-push 6.0 on #936's head | measurement and qa-push (#936, #938), codex-egress (#939) | most read the gate probe |
| grafana-dashboards | 2.6 mean built (57 of 83 flake-check runs); 3.6 on 26 Nov 07:07 UTC | #814 | black-pi's dashboards and rules |
| execution-pool-vm | 6.1 built on 26 Nov 07:07 UTC (45 compiled), 11.7 on 26 Nov 03:20 | `execution-pool-vm` (#795) | `modules/workers/`, `pkgs/exec-pool/` |
| pool-merge-check: host evaluation | 57 s mean over 461 evaluations, 441 min in 24 h (to 26 Nov 10:00 UTC) | lenovo's sam.memory budget (#794, #799) | the host's modules and `hosts/<dir>/` |
| pool-merge-check: package build | 162 s mean over 27 builds in 24 h | c15a3024 (#795) | `pkgs/<dir>/` |
| A deploy of acer | about 50 with four slots busy (per coordinator); four slot memory kills beside it | none traced | acer's closure, slot load |

The slowest, by minutes, with the cut for each:
1. Host evaluation: pool-merge-check's 441 min in 24 h and the gate probe's 507 s a run, plus seventh-host and
   workers-eval evaluating the hosts again. Cut: one shared evaluation (follow-up 2). #924's tree-keyed record
   skips a tree already evaluated; its day-later read is owed (Owed reads).
2. The flake check under slot load: 2759 s on 26 Nov against 1373 s on 24 Nov, with four acer slots evaluating
   beside it. Cut: the gate alone on acer (follow-up 1), cargo under the lock (#876).
3. A deploy of acer beside busy slots: about 50 min and four memory kills. Cut: acer deploys batched at night.

Follow-ups, in order: (1) the scheduled gate alone on acer; (2) one evaluation of every host shared by the probe,
the flake check and seventh-host; (3) the flake check's per-output evaluations in fewer processes (queue 14).

### Where the time goes, and what a cache can save (Loki, read from a slot on 25 Nov)

The answer to "how much would a cache save": at most the 500 s of building, 22 % of the 24 Nov gate. Evaluation is
about 1170 s, more than half of it: the probe, the flake check, workers-eval and seventh-host each evaluate the hosts
on their own. acer's slots build through acer's daemon into the store its harmonia serves, and lenovo substitutes
from acer. `modules/core/store-upload.nix` (#839) has msi and asus queue each built output with a `post-build-hook`;
acer pulls the paths from the sender's harmonia and keeps them under gcroots, 14 days and 100 GiB. StoreUploadStuck
(#857) and StoreUploadStale (#891) fire on a sender acer does not take from.

### Escapes still without a narrow check

| Escape | Smallest check that would catch it |
|---|---|
| #777: every pane turn on acer failed with a herdr parse error | one session turn through a pane on a slot before the merge |
| #912: `pkgs/scheduled-gate` failed ruff E501 in its checkPhase at build, so acer's and msi's deploys stopped at b46a64e3 (fixed by #931) | a PR touching `pkgs/<name>` builds that package (`nix build .#<name>`; `pool-merge-check`'s package build) as its narrow check |
| #926: exec-pool's `tests/queue.rs` expected one report line, so the package build stopped acer's deploy at 4546f4ae (fixed by #935); the PR ran `cargo test --bin exec-pool` only | the same rule: `nix build .#exec-pool` runs every test target and the package's postCheck |

Rule for every session: a reply states the minutes of each check it ran and what any failure caught. An escape gets
a row above and a narrow check, not a longer gate.

## Owed deploys and reads

Deploy order: msi and asus in their power window (08:30 to 21:00 CET), acer batched at night (about 02:30 or 07:30
CET, per coordinator), lenovo when its pool or coordinator changes need it.

| Host | Running | Owed |
|------|---------|------|
| msi-ms7758 | `3ae473ac` (per coordinator; the deploy at `b46a64e3` failed its checks) | main, for the pool runner changes (#913, #943, #944, #948) and everything since `3ae473ac` |
| asus-b460m | behind since 25 Nov (per coordinator) | everything since 25 Nov plus #949's `rgb-off`, before its 21:00 CET power-off on 27 Nov, after an asus toplevel build on acer by day; not while the agent `paddock` measures (finding 7) |
| acer-swift | confirmed after #913 (per coordinator) | #943, #944 and #948 at the next night batch |
| lenovo | `0bd1b958` (per coordinator) | nothing queued that needs it |

Day-later reads, on 27 Nov evening (per coordinator):
- nixos-push-eval and pool-merge-eval minutes per day against 841 and 503 min per 7 d, and the `result=cached`
  counts (#924, brief 212).
- asus's RGB lights off after its 21:00 power-off, read at 21:15 CET (#949, brief 228).

## Hosts and slots

Placement order: acer, then msi, asus last (it carries ollama, Paddock and the GPU). At night only acer and lenovo
take work.

| Host | Slots | Note |
|------|-------|------|
| acer-swift | `pool1` to `pool4` | Shunt on `pool1`; `pool4` light (1G reserve, CPUWeight 100 against 200, CPUQuota 200%), the slice 9G; offers claude and pi, and codex on the owner's ChatGPT login; Paddock briefs 229 and 230 run here |
| msi-ms7758 | `pool1` to `pool4` | offers claude; off 21:00 to 08:30 |
| asus-b460m | none | ollama (one resident model, 130 W cap), `paddock.service` (Qwen3.6 35B, #817, #822), agent `paddock`; off 21:00 to 08:30. By day the agent `paddock` runs the GPU repro, the baseline runs, the pack rebuild check and the over-window repro through Pi, and takes fork PRs 18 to 21 into its build (per coordinator; GitHub shows all four merged into asus/biggest-moe). The fork's main is 3 commits behind upstream, so briefs branch from `upstream/main-mirror` (per coordinator) |

Pool4's price: with four acer slots, keep it while acer's 24 h throttle increase stays within half again of the
three-slot day and the memory kills fall below 26 Nov's bursts (`sum(increase(node_cpu_core_throttles_total{node="acer-swift"}[24h]))`,
`max_over_time(homelab:node:hwmon_temp_max_celsius{node="acer-swift"}[24h])`, `exec_pool_memory_kills_total`);
otherwise drop it (`slots = 3`, `light.slots = 0`). lenovo's first slot is not in this layout yet.

No slot holds a GitHub key: slots push through acer's GitHub sidecar and private clones go through the proxy.
Gaming entries on asus and msi are merged and booted on neither host yet; the owner accepted them untested (#645).

## Horizon (direction only, no work scheduled)

- The pool as a coding platform: any repository, guest users (vision.md).
- The app platform, epic [#557](https://github.com/sammasak/nixos-config/issues/557): next step is to register one
  real app. Apps in the registry today: 0.
- devenv-platform#156 to #166, workload orchestration research: vision.md names no container orchestrator.
