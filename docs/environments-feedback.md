# Environment feedback ledger

What working real issues in the nspawn environments (`docs/nspawn-workers.md`)
taught, one line each. `fixed` names the change; `open` is a gap to close.
Append; move a line to fixed when its change lands.

## Open

- Secretless GitHub rollout (acer `push`, 2026-11-12): an environment moved onto the proxy keeps dangling `~/.ssh/id_ed25519` and `~/.config/gh/hosts.yml` links in its persistent home (harmless, the targets are gone; a tmpfiles `r` rule would remove them), and a retired instance leaves an empty `/run/dev-env-egress/<name>` until the proxy next restarts.

- The reserve is hard between environments (`MemoryMin`) but soft against the host: `environments.slice` has only `MemoryLow`, and cgroup2 is mounted without `memory_recursiveprot` on acer and msi (a second cgroup2 mount at `/run/cilium/cgroupv2`). Not measured under host pressure (docs/environments-plan.md, item 3).
- Inside the Claude sandbox (acer, after #244) these still fail: `nix build nixpkgs#hello` (`cannot create Unix domain socket: Operation not permitted`, so the nix daemon is unreachable), `free` (`Memory information file /proc/meminfo does not exist`), `uptime` (`Cannot get system uptime: No such file or directory`), `htop`. `top` sees 6 tasks. `ps`, `nproc` and `git status` work; `pgrep` sees no host process.
- Nested sandboxes (acer `push`, 2026-11-12): nspawn's masks on `/proc` make the kernel refuse a full procfs in any nested user and pid namespace; the clean fix is nspawn's (systemd#34226, open). `subset=pid` works but has no `/proc/sys`, `meminfo`, `cpuinfo`, `stat`: `free`, `uptime`, `sysctl` fail; `nproc`, cargo and daemon `nix build` work.
  - bwrap 0.12 cannot start on a subset proc (reads `/proc/sys/kernel/overflowuid`). Works: bind the outer `/proc`, mount `subset=pid` from inside as mapped uid 0, then run the command as mapped root with only `CAP_SETFCAP` and no-new-privs (wrapper verified by hand, also under `claude -p` with the sandbox on).
  - podman 5.8 and buildah: no flag for the proc mount options. Works: an OCI runtime wrapper named crun in `containers.conf` via `engine.runtimes`, adding `subset=pid` to the bundle's `/proc` mount (`podman run`, `podman build` and `buildah bud` verified by hand), with the vfs driver (no `/dev/fuse`), cgroupfs, and `--network=none` (no `/dev/net/tun`).
  - Claude Code `/sandbox`: `sandbox.enableWeakerNestedSandbox` binds the outer `/proc` (pid view of the whole guest); `sandbox.bwrapPath` (managed settings only) points at the wrapper, which ran under a real `claude -p`; the wrapper is packaged (#239) and verified in a deployed guest on acer.
- Guest `nix.conf` lists substituters and keys twice (the guest's defaults plus the inherited ones).
- `nixos:nvim-check` rewrites `dotfiles/nvim/lazy-lock.json` in the working tree; a hook that fails to build leaves the previous pre-push gate active with no warning; `nixos:qa` prints no per-step timings; `file` and `strings` are not on a guest's PATH.
- `pkill -f <pattern>` from an agent's tool shell matches the shell's own command line and kills it (exit 144, twice today): use `pgrep -x` or a pid.
- Herdr reports `done` while an agent waits on its own background shell or subagent (`f44` three times in one issue); a watcher keyed on status alone wakes for nothing or, worse, retires too early. The coordinator reads the pane tail first (docs/nspawn-workers.md step 4).
- Two environments on acer running Rust gates plus the nixos-config gate share the host daemon's two build cores: the nixos-config gate that takes 11 min on msi alone was past 35 min. One heavy gate per host at a time, or raise the daemon's cores when the pool is the only load.
- A fresh clone has no git hooks until `devenv shell` runs once, so `nc200` pushed its nixos-config branch with no pre-push gate at all (docs only, so harmless this time). The brief should say "enter the devenv shell once before the first commit", or the guest should refuse a push from a repo with a devenv.nix and no hooks.
- On acer and in its environments `lenovo-21CB001PMX` resolves to 127.0.0.2, and an environment has no key for other fleet hosts: an artifact that lives only on another host (a bundle) is unreachable. Hand-offs between hosts go through a pushed branch; the coordinator copied the factum#44 bundle in by hand.
- A path is cold once per host store, so an issue asking for three cold repetitions cannot be met from an environment.
- The host's Nix daemon socket is reachable from an environment (by design: that is what makes the shared store instant), so the devenv-platform#120 invariant "daemon socket inaccessible" does not hold here. An environment isolates files and resources, not the daemon.
- Task prompts said "read CLAUDE.md" for repos that have none (herman, devenv-platform); the coordinator's brief should say "the repo's entry doc".
- The `playwright-login` MCP server fails in an environment (`ENOENT .../claude-playwright-login/state.json`); one Playwright MCP with an isolated context per device works. Either seed the state file or drop that server from the guest.
- Playwright MCP screenshots resolve `filename` against the agent's start directory (the home), not the repo; files had to be moved.
- msi sets no `ghHostsFile` (its user has no gh login), so its guests hold the SSH key, not the proxy, and the agent cannot read issues or open PRs there: the issue text is copied in and the PR opened from lenovo.
- Declaring an environment is a nixos-config commit, and every push runs the full `nixos:qa` (about 20 minutes, only safe from msi). Too slow for routine add/remove; instances are deployed from uncommitted edits meanwhile.
- A second `exit` in an environment's pane (from the shell left after the agent quits) returns the pane to the host shell.
- Codex is not signed in on acer or msi.
- The hand-over brief is typed by hand; the coordinator does not yet check for an existing PR or build the brief. Twice the issue already had a PR: every brief must say "check for an existing PR first". Issue texts also go stale against merged work.
- herman and skills have no `sdlc:*` stages, so agents ran the repos' gates directly.
- skills `skills:test` runs its suites in parallel: run suites one at a time in an environment.
- skopeo and buildah are on PATH only inside `devenv shell` (by design, note only).
- Herdr's `agent prompt` with a multi-line prompt is untested: the shell layer keeps the newlines, whether Herdr types them as Enter is not known.
- The host user's uid is assumed 1000 (mutableUsers, no declared uid); `clientKey` and `ghHostsFile` are home files whose existence only shows at container start. Not declared fleet-wide: black-pi's user is uid 1001. Side find: `core/automation.nix` reads the same undeclared uid, so its upgrade notice looks in `/run/user/`.
- Owner decision: msi environments and any instance without `egress.github.repos` still hold the user's GitHub ssh key (msi has no gh token), so an agent can push to nixos-config `main`, which acer applies weekly as root. Mitigation: branch protection on `main`, or a scoped key. With `egress.github.repos` (acer) neither.
- acer still has `/nix/var/nix/{profiles,gcroots}/per-container/worker-1` from the old naming (the cleanup loop that removed msi's is gone): `sudo rm -rf /nix/var/nix/profiles/per-container/worker-1 /nix/var/nix/gcroots/per-container/worker-1`.
- First `devenv shell` in a new environment is 25 to 32 s of evaluation. Seeding a new home's `~/.cache/nix` from the host user's was not done: copying the live sqlite fetcher cache can corrupt it, and the cost looks like devenv's per-repo evaluation, not fetching. The empty `flake-registry` only removes the global registry fetch.

- 2026-11-11 `nc201`: on lenovo the guest is `Trusted: 1` on the host daemon, because the guest user is the host
  user and lenovo keeps that user trusted. The doc said otherwise; corrected. Untrusting needs a different guest uid
  or a host without a trusted login user; owner decision with the nested /proc one.
- 2026-11-11 `nc201`: `devenv shell` bootstrap prints about 10k characters of git progress into the agent's tool
  output. Briefs now say to send heavy command output to a log file.
- 2026-11-11 `nc201`: the issue's baseline code and links were stale against main. Briefs now say to check an
  issue's references against HEAD first.

- 2026-11-11 `h2`: an acceptance criterion like "the template renders in `gh issue create`" cannot be checked before
  merge (gh reads the remote default branch and wants a TTY). Not an environment gap; issues should word such
  criteria as post-merge checks.

- 2026-11-11 `dp93` (lenovo): an environment deployed from the coordinator's branch is ahead of main, so the agent
  finds itself undeclared at HEAD. Cause: the gate takes 38 min on acer, so deploys run before the merge. Goes away
  when msi (11 min gate) is up, or the brief names the branch.
- 2026-11-11 `dp93`: a store-cold run cannot be measured from an environment (shared store, no purge); `du` on
  `/nix/store` is unusable there, `nix path-info --all -s` works. Briefs should say "cold = first shell in this home".

- 2026-11-11 `f44`: reviewer grades on one axis moved 8, 8, 7 across rounds on near-identical trees, so a "9 on
  every axis" bar can be missed by noise alone. One review round plus one fix round is the limit a brief should set.
- 2026-11-11 `f44`: artifacts named in an issue as a path on another host (a bundle under lenovo `~/exports`) are
  unreachable from an environment. Hand-overs between hosts go through a pushed branch.
- 2026-11-11 `dp120`: repos without a CLAUDE.md cost the agent a long README read; `devenv shell` warns
  "devenv 2.4.0 newer than lock input 2.2.2" on every run in devenv-platform.

- 2026-11-11 `dp121`: the guest's own `nix.conf` shows max-jobs 8, cores 0; the daemon's real 2 x 2 limit is not
  visible from inside, and builds run by the daemon have no per-environment CPU or memory accounting. Benchmarks
  taken in an environment must say so; identical rebuilds varied 3:54 to 7:20 beside another environment's gate.
- 2026-11-11 `dp121`, `nc200`, `dp93`: "cold" cannot be produced in an environment (shared store). Benchmark issues
  that need cold runs need msi with nothing else running, or the owner's go for a throwaway store.

- 2026-11-12 msi at #242: sandboxed commands run as mapped uid 0 with 10 process entries and 8 CPUs, a home write
  outside the working directory is refused, `podman run --network=none` works. Same as acer.

- 2026-11-12 From inside an environment the pool is invisible: its cgroup files read `max` and `0`, `memory.peak` cannot be reset, and there is no kernel log, so a job cannot size itself and cannot tell why it was killed (`mem`, msi).
- 2026-11-12 An agent's 10-minute command cap kills the wrapper shell and leaves the child running: a stalled allocator ran on for 18 minutes until it was killed from the host. Wrap long steps in `timeout`.
- 2026-11-12 `claude -p` from an agent's tool shell says "Not logged in" until `CLAUDE_CODE_OAUTH_TOKEN=held-by-the-host` is set by hand.

## Fixed

- 2026-11-12 A runaway with incompressible data took msi itself out of memory: the 10G pool plus its 5G of swap is 15G of real RAM on a 16G host, because zram keeps what does not compress in RAM. The kernel's host-wide OOM killed k3s pods (node_exporter, ollama) and a process in the neighbouring environment at 13:46. The pool's swap is a quarter of the pool now (msi 12.5G worst case). Size a pool so that pool plus a quarter fits beside the host's own use.
- 2026-11-12 With no ceiling per environment a 17G runaway on msi was not killed: the pool's `MemoryHigh` throttled it for 18 minutes at the limit and the idle neighbour was reclaimed from its 2G `MemoryLow` reserve to 59M. The pool has no `MemoryHigh` now and the reserve is `MemoryMin`: the same runaway was killed after 23 s, that process only, and a neighbour holding 1.5G kept it. Replicated from inside the `mem` environment with incompressible data: killed after 30 s (`oom_kill` +1, `low` +0), a 1.5G working set beside it slowed for one pass (0.11 s to 0.76 s), agent and shell alive.
- 2026-11-12 `ps -e` in Claude's sandbox failed with `lookup self` (#244): `ps` and `top` run there (acer).
- 2026-11-12 A guest's own nix client (devenv, a local `--store`) waited out the LAN block per substituter lookup: the caches' port is excepted and the guest takes the host's `connect-timeout`. `delegation-test` on msi 467 s to 16 s (#237).
- 2026-11-12 Host reboot kills what runs in an environment: a resumed agent now gets a restart notice (`modules/workers/default.nix`); checked on acer and msi.
- 2026-11-12 No fresh /proc in a nested user namespace: bwrap and podman/buildah wrappers mount `subset=pid` (#239, `modules/workers/nested-sandbox.nix`).
- 2026-11-12 The Claude token is held by the host proxy (#235, #236) and `credentials` gives an instance a subset of the host's files, so "research only" can be structural.
- 2026-11-12 An environment's own 6G `MemoryMax` got a gate's `nix` process killed on msi (3.9G anon, `oom_kill 1`, `memory.max` hit 54183 times) with one environment running, 4G of the 10G pool idle and 11G free on the host. `memory.max` and the swap cap per environment are gone: the pool is the only ceiling, the reserve the only setting.
- Nested sandboxes (#239): open friction from the round that built it, kept for the next one: the placeholder Claude token is in the login environment but not in tool shells; Claude's wrapper puts its own bubblewrap first on PATH, so only managed settings can swap it; `--settings` ignores `sandbox.bwrapPath` without a warning; a fresh clone has no gate hooks until `devenv shell` has run once. One `podman run` right after the deploy failed with rootful storage paths and did not reproduce.

- 2026-11-12 A guest's builds ignored the host's build bounds: the daemon takes a client's `max-jobs`/`cores` over its own, and a guest sent 8 jobs on all cores against the host's 2 x 2. Four independent 20 s derivations from an acer guest: 21 s with `NIX_BUILD_CORES=8` before, 41 s with 2 after the guest inherited the host's values (#230). The nixos-config gate is no slower bounded (9m09s against 9m02s to 9m24s).
- 2026-11-12 The shared `~/.cache/nix` held Nix's evaluation cache, unsigned rows naming the derivation to build; each environment now mounts its own over `eval-cache-v6` (#230), the fetcher and tarball caches stay shared.
- 2026-11-12 `blockedNetworks` at runtime on acer next to Cilium (#231): from a guest the host's sshd and k3s API (veth and LAN address), harmonia, lenovo, the Traefik address and a cluster service address are all closed; DNS, github.com over https and ssh, and the host's nix daemon work; cluster and host healthy after the deploy.
- 2026-11-12 Environments skipped the fleet's store caches: the guest's nix.conf listed only the public substituters, and the host's daemon takes a client's list when it trusts every entry. factum's first `devenv shell` on msi fetched nothing from acer, which had all of it. The guest now carries the host's list.
- Host reboot on acer (2026-11-12, `systemctl reboot` with one environment declared): system `running` with no failed units, `environments.slice` and the instance's limits back (7G pool, 2G reserved, 6G max, 3G swap), nix-daemon up, container starting 7 s into userspace, its agent idle in the host's Herdr at 15 s, home files kept, host store and shared `~/.cache/nix` mounted, first `devenv shell` in an existing clone 7.4 s. Rebooted again with a conversation in the agent: it came back in that conversation and recalled a token given before the reboot.
- Host reboot on msi (2026-11-12). Cold boot on the generation it was switched off with: `running`, no failed units, 10G pool back, its one environment starting 7 s into userspace with the agent in its old conversation. Then deployed from main (old environment retired, two new ones) and rebooted: both containers starting 6 s into userspace, both agents in Herdr at 14 s, home files kept, token recalled, `devenv shell` 8 to 10 s.
- Shared store and cache on msi (2026-11-12): the first `devenv shell` of llm-gateway, a revision msi had never built, took 4m25s; again in the same environment 7.5 s; in a brand-new environment with a fresh clone 8.7 s.
- Bursting on msi (2026-11-12): a process in an environment with 2G reserved and 6G max allocated 7.5G and finished: throttled at MemoryHigh (peak 5.8G), 3.2G in swap, `oom_kill 0`.
- 2026-11-11 A fresh home re-downloaded and re-unpacked every flake input although the store held the result: Nix's fetcher cache is per user home. Measured on acer with llm-gateway, warm store: 31 s with an empty `~/.cache/nix`, 6.8 s with a warm one. `~/.cache/nix` is now one host directory bound into every environment; a brand-new environment's first `devenv shell` took 5.9 s. Cost: environments share that cache (same trust domain as the shared daemon).
- 2026-11-11 Gate timing on acer from inside an environment: 9 m 53 s alone, 21 to 38 min beside another environment's gate.
- 2026-11-11 `dp121` on acer (devenv-platform #121, G0 and G1): baseline measured and the RFC comment posted in 33 minutes beside herman's gate in `f44`; pool at its 7G cap, 370M swap, no OOM kill. Stopped at owner gate D1. Retired the same sitting. Every approved issue is now at an owner gate, so the pools are empty by design, not idle.
- 2026-11-11 `f44` on acer (factum #44 slice 3): PR #49 pushed through factum's own gate at review grade 8 and left for the owner (project bar 9). Before retiring it served as the push vehicle: two nixos-config gates (22 and 21 min) and the herman #2 branch. Retired after pushing its own retirement.
- 2026-11-11 `dp120` on acer (devenv-platform #120, G1 parity evidence): issue to merged docs PR #123 in 14 minutes while a second environment ran the nixos-config gate; pool at 2.1G of 7G. D1 stays with the owner. Retired the same sitting.
- 2026-11-11 `dp93` on lenovo (devenv-platform #93, research): first `devenv shell` of llm-gateway in a fresh home 33.9 s and +0.26 MiB of host store (closure already there), warm 5 s, zero new paths. That is the shared store doing its job. Guests now have `bc` and an empty `~/ENV-FEEDBACK.md`. Retired the same sitting.
- 2026-11-11 `h2` on lenovo (herman #2, docs and issue template): declared to reviewed commits in about 2 minutes on a warm host, no gate run on lenovo. Retired the same sitting; the branch went out through an acer environment.
- 2026-11-11 `nc201` on lenovo (nixos-config #201, G0 inventory, research only): issue to reviewed commit in a 4G pool beside k3s with no gate run on lenovo; the coordinator fetched the branch over ssh and pushed it through an acer environment's gate. Retired the same sitting.
- 2026-11-11 The full nixos-config pre-push gate ran inside an environment (`nc200` on acer, nixos-config #219): green in 38 m 16 s beside a second environment's Rust gate (11 min on msi alone), peak 5.5G at the 6G cap with the 3G swap allowance full, throttled, no OOM. Pushes no longer need msi awake. `nc200` retired after pushing its own retirement.
- 2026-11-11 Results: llm-gateway#88 follow-up (PR #92) merged from `gw88` on lenovo in 14 min. Its `rust:ci` (427 tests) ran inside the 4G pool: peak 3.7G, throttled at MemoryHigh, 340M to swap, no OOM, host never below 9G available. `gw88` retired; lenovo keeps the pool settings so the next one is one line.
- 2026-11-11 Parallel work on acer failed with "Could not resolve host: github.com" (the nixos-config gate's nvim plugin clones, run from `nc200`): AdGuard Home on lenovo rate-limits each client to 20 queries/s by default. 40 parallel lookups: 20 failed on the acer host, 18 in the guest; with `ratelimit = 0` both 0. Not an environment defect, but environments make it likely by running more at once.
- 2026-11-11 Results: nixos-config#200 G1 baseline (PR #218) merged from `nc200` in 5 m 42 s from declaration to PR. `gw88` declared on lenovo (4G pool) for llm-gateway#88: first environment on the control plane.
- 2026-11-11 Results: devenv-platform#93 evidence (PR #122) merged from `dp93`: started from its declared prompt with no hand-off, cold `devenv tasks list` 83 s on a repo new to the host, `platform:verify` 21 checks green in 20 m 32 s run alone. `dp93` retired.
- 2026-11-11 Results: herman#4 (PR #39, baseline G1 to G10 run with 58 screenshots) merged from `demo`, issue closed; `demo` retired after three issues (herman#5, #18, #4).
- 2026-11-11 Finished environments sat idle holding their reserve (`skills91` for hours after skills#97 merged). Rule added to the process (docs/nspawn-workers.md, "Tear down when done"): retire in the same sitting once clones are clean and feedback is copied out. `skills91` retired.
- 2026-11-11 Results: herman#18 (PR #37, after a dependency PR #38 for advisories) merged from `demo`; without the CPU cap its warm rust:ci went 253 s to 170 s, verify-web 828 s to 479 s, web-dist 142 s to 63 s. A second acer environment (`dp93`) started from its declared prompt with `demo` untouched.
- 2026-11-11 Verified on msi: live resize with no restart; undeclare keeps the home, `retired` deletes it; four deploys in a row left the neighbouring environment's start time unchanged; guest boot 6.8 s to 1.9 s.

- 2026-11-11 Any deploy that lacked an instance (a rollback, an older checkout, acer's weekly auto-upgrade from `main`) deleted its home: only names in `retired` are deleted.
- 2026-11-11 Every nixpkgs bump restarted every environment (store paths in `worker-<name>`'s unit): the unit now holds only the instance's agent, model, address and binds; resize and prompt edits do not restart.
- 2026-11-11 Guests presented the host's own sshd key, so root in a guest could pose as the host: one generated environments key per host, trusted on first use from lenovo.
- 2026-11-11 GC roots missed `~/.cache/wt/<repo>/.devenv/gc` (depth limit): a pruned search of the whole home.
- 2026-11-11 At a cold boot the Herdr hook could give up before the user's Herdr was up: it wants `user@`, fails on timeout and restarts.
- 2026-11-11 Guests booted an unused Herdr server, repo-sweep (which would reclaim the agent's clones), flake-update, gpg-agent, dconf and a firewall: all off in the guest.
- 2026-11-11 Builds from environments ran in an unbounded host daemon: acer and msi bound it like lenovo.
- 2026-11-11 Host GC would have deleted environments' devenv shells (roots dangled on the host): `dev-environments-gcroots` before `nix-gc`.
- 2026-11-11 Pushes dropped by GitHub during long pre-push gates (seen three times): ssh keepalive in every environment.
- 2026-11-11 An environment could fill the host's zram swap: swap capped at half its memory max.
- 2026-11-11 Per-container dirs of names from an earlier scheme needed root to remove: a one-time activation loop cleared msi's (since removed; acer's are in Open).
- 2026-11-11 Hard caps throttled idle hosts: reserve plus spike in one slice; without the CPU cap herman web-dist went 151 s to 142 s (mostly serial compile, small win), 7G allocation in a 6G environment survives.

- Every nix command in an environment warned about root's missing channels on stderr (broke a test capturing stderr): guests pin `nix.nixPath` to the store's nixpkgs, channels off (`modules/workers/core.nix`).
- `/usr/bin/time` missing: guests carry `pkgs.time` (`modules/workers/default.nix`).
- Done in environments and merged, each with one in-session subagent review that found real bugs in two of three: herman#5 (PR #34), skills#91 (PR #95), a red-main test fix (skills PR #96).

- Hard per-instance caps (`memoryMax`, `cpuQuota`) throttled agents on idle hosts (msi hit memory.max 20138 times): reserve per environment, spike to a per-host pool (`modules/workers/core.nix`, docs Sizing).
- A wrong declaration (name, agent/model/prompt, sizes, user, keys, jump hosts) failed at runtime or not at all: it now fails eval, one case each in `nixos:workers-eval-test`.
- The agent command was quoted twice (bash, then fish through ssh), safe only because the model pattern excluded quotes: it is now a store file the guest's shell sources.
- `sshKey = null` evaluated but left the Herdr pane no way to log in: the option is no longer nullable.

- Quitting the agent dropped the pane to the host shell: the session now ends in a shell inside the environment (`modules/workers/default.nix`, `remoteCommand`).
- First acer environment booted without DNS (host `resolv.conf` empty mid-deploy): the container waits for a nameserver before starting.
- herman#5 was handed out although PR #34 already implemented it; the agent caught it. Step 1 of the process now checks for an open PR.
- The brief named `CLAUDE.md`, which herman does not have: briefs name no file, the agent finds the repo's guidance.
- `nixos:worker-permissions-test` read `spawn.nix` from the skills input and a numbered container; it now checks the workers module and a probe instance that replaces the committed ones.

- 2026-11-12 the Claude login left the guests (#235, #236), acer and msi: `claude -p` answers through the host
  proxy with the placeholder token; no token file under `/var/lib/host-credentials` or `/run/secrets`, none in any
  process environment the guest user can read, none in the home (`sk-ant-oat` matches only a plugin's docs). The proxy's
  journal shows `POST /v1/messages` 200. The token the guests read before is still valid: rotation is the owner's.
- 2026-11-12 bounded builds (max-jobs 2, cores 2) cost the nixos-config gate nothing on msi: every step within 1 s
  of the unbounded run, peak 5.5G, `memory.events high 0`. #233 (reclaim threshold at the pool) has no throttling
  left to remove there; acer's 2913 is the case it addresses, to be re-counted at the next gate on acer.

## Time to shell

msi `gate`, 2026-11-12, bounded builds, `devenv shell -- true`, one run at a time (nixos-config #200). Fresh = new
clone, no `.devenv`, emptied eval cache; the host store cannot be emptied from a guest.

| Repo | Fresh 1 | Fresh 2 / 3 | Warm |
|------|------:|------:|------:|
| devenv-platform `examples/rust-service` | 101.7 s | 9.5 / 9.3 s | 7.2 s |
| factum | 6.7 s | 6.4 / 6.6 s | 1.0 s |
| nixos-config | 7.5 s | 7.6 / 7.8 s | 0.4 s |

- With the closure in the host store a fresh repo costs 6 to 10 s, nearly all one uncached evaluation.
- The 101.7 s run: about 50 s of Rust toolchain from acer's cache, 29 s building `devenv-nixpkgs-patched` locally
  (no cache had it), 10 s of flake inputs. Nothing from cache.nixos.org. Building that path once on a serving host
  when the pin moves removes the 29 s elsewhere.
- devenv-platform's example misses devenv's eval cache on every warm run (7.2 s). Suspected, not confirmed: its
  `path:../..` input includes the example's own `.devenv`.
- `memory.events` all zero over the 18 runs.

## Gate timing

After #237 (msi `gate`, bounded builds, fresh clone): `nixos:delegation-test` 16 s (was 467 s with the LAN caches blocked, 12 s before bounds), full `nixos:qa` 221 s (was 671 s, 204 s before bounds). `memory.events` all zero, peak 5.2 GiB.


`nixos:qa` per step on msi-gate, warm store, seconds, before (`f4f6b87`) and after `feat/gate-speed-tests`, both with unbounded builds (max-jobs 8, cores 0).
Total 690 s before, 218 s after (207 s before workers-eval's type cases went to two at a time after the batch, for memory). Every PASS line is unchanged but one
(workers-eval's nftables case now lists only the module's own assertion). A docs-only push now runs the lints alone.

| Step | Before | After | Change |
|------|-------:|------:|--------|
| lint-comments, lint-shell, secrets-verify | 1 | 1 | |
| nvim-check | 19 | 0 | values from the probe |
| flake-check | 56 | 57 | unchanged; it already built every x86 host (deploy-activate) and evaluated the Pis |
| verify | 59 | — | removed: repeated flake-check |
| gate-probe (new) | — | 28 | one evaluation of every value the tests read (`scripts/gate-probe.nix`) |
| native-otel-relay, native-otel-fish | 4 | 2 | relay helper from the probe |
| claude-settings | 14 | 2 | paths from the probe |
| coordinator-wiring | 56 | 21 | 12 nix calls to the probe; 20 s of it is the script's own lock wait |
| worker-permissions | 245 | 32 | ~25 nix calls to the probe; the three 30 s startup screens side by side |
| workers-eval | 134 | 46 | non-type cases in one process (only core.nix's assertions), then the type cases two at a time |
| ollama-portforward | 16 | 11 | the rest is the test's own sleeps |
| known-hosts | 14 | 1 | 10 nix calls to the probe |
| build-bounds | 5 | 0 | |
| delegation | 16 | 12 | the rest is devenv |
| otel-rollback | 30 | 5 | 15 nix calls to the probe plus one evaluation of the rolled-back copy |
| rf-lab-boundary, runtime-host, rf-beacons | 18 | 0 | |
