# Environment feedback ledger

What working real issues in the nspawn environments (`docs/nspawn-workers.md`)
taught, one line each. `fixed` names the change; `open` is a gap to close.
Append; move a line to fixed when its change lands.

## Open

- Herdr reports `done` while an agent waits on its own background shell or subagent (`f44` three times in one issue); a watcher keyed on status alone wakes for nothing or, worse, retires too early. The coordinator reads the pane tail first (docs/nspawn-workers.md step 4).
- Two environments on acer running Rust gates plus the nixos-config gate share the host daemon's two build cores: the nixos-config gate that takes 11 min on msi alone was past 35 min. One heavy gate per host at a time, or raise the daemon's cores when the pool is the only load.
- A fresh clone has no git hooks until `devenv shell` runs once, so `nc200` pushed its nixos-config branch with no pre-push gate at all (docs only, so harmless this time). The brief should say "enter the devenv shell once before the first commit", or the guest should refuse a push from a repo with a devenv.nix and no hooks.
- On acer and in its environments `lenovo-21CB001PMX` resolves to 127.0.0.2, and an environment has no key for other fleet hosts: an artifact that lives only on another host (a bundle) is unreachable. Hand-offs between hosts go through a pushed branch; the coordinator copied the factum#44 bundle in by hand.
- A path is cold once per host store, so an issue asking for three cold repetitions cannot be met from an environment.
- The host's Nix daemon socket is reachable from an environment (by design: that is what makes the shared store instant), so the devenv-platform#120 invariant "daemon socket inaccessible" does not hold here. An environment isolates files and resources, not the daemon.
- Task prompts said "read CLAUDE.md" for repos that have none (herman, devenv-platform); the coordinator's brief should say "the repo's entry doc".
- The `playwright-login` MCP server fails in an environment (`ENOENT .../claude-playwright-login/state.json`); one Playwright MCP with an isolated context per device works. Either seed the state file or drop that server from the guest.
- Playwright MCP screenshots resolve `filename` against the agent's start directory (the home), not the repo; files had to be moved.
- msi environments have no `gh` login (acer binds the host's `hosts.yml`): the agent cannot read issues or open PRs, the issue text is copied in and the PR opened from lenovo. Needs a GitHub token bound into every environment.
- Declaring an environment is a nixos-config commit, and every push runs the full `nixos:qa` (about 20 minutes, only safe from msi). Too slow for routine add/remove; instances are deployed from uncommitted edits meanwhile.
- A second `exit` in an environment's pane (from the shell left after the agent quits) returns the pane to the host shell.
- Host reboot recovery is checked on acer only (2026-11-12, see Fixed). Still open: msi. A host reboot kills whatever runs in an environment (a gated push was lost) and nothing restarts it; the agent resumes its conversation but is not told.
- Codex is not signed in on acer or msi.
- The hand-over brief is typed by hand; the coordinator does not yet check for an existing PR or build the brief. Twice the issue already had a PR: every brief must say "check for an existing PR first". Issue texts also go stale against merged work.
- No fresh /proc mount in a nested user namespace (untested fix, none applied): rootless buildah `RUN` fails "mount proc to proc" (herman uses `--isolation chroot`), bubblewrap fails "Can't mount proc on /proc" (skills bundle-sandbox test). The kernel refuses it because nspawn overmounts parts of /proc (`/proc/sys`, `/proc/sysrq-trigger`, ...), so no fully visible proc exists in the guest. `SYSTEMD_NSPAWN_API_VFS_WRITABLE` only makes those mounts writable, `additionalCapabilities`, `--system-call-filter` and `enableTun` do not remove them, and `privateUsers` keeps them. What works is binding an unmasked proc into the guest (`extraFlags = [ "--bind-ro=/proc:/run/proc" ]` with `/sys` likewise): it shows every host process and its cmdline (k3s included) to agents running with bypass permissions, so it widens the trust boundary and needs an owner decision. Meanwhile: `--isolation chroot`, or run such tests on a host.
- herman and skills have no `sdlc:*` stages, so agents ran the repos' gates directly.
- skills `skills:test` runs its suites in parallel: run suites one at a time in an environment.
- skopeo and buildah are on PATH only inside `devenv shell` (by design, note only).
- Herdr's `agent prompt` with a multi-line prompt is untested: the shell layer keeps the newlines, whether Herdr types them as Enter is not known.
- The host user's uid is assumed 1000 (mutableUsers, no declared uid); `sshKey` and `ghHostsFile` are home files whose existence only shows at container start. Not declared fleet-wide: black-pi's user is uid 1001. Side find: `core/automation.nix` reads the same undeclared uid, so its upgrade notice looks in `/run/user/`.
- Owner decision: guests hold the user's GitHub ssh key and gh token, so an agent can push to nixos-config `main`, which acer auto-upgrades from weekly as root. Mitigation: branch protection on `main`, or a scoped key.
- acer still has `/nix/var/nix/{profiles,gcroots}/per-container/worker-1` from the old naming (the cleanup loop that removed msi's is gone): `sudo rm -rf /nix/var/nix/profiles/per-container/worker-1 /nix/var/nix/gcroots/per-container/worker-1`.
- `blockedNetworks` (forward drop to the LAN, DNS excepted) is wired but off: needs a runtime check that GitHub, DNS and host-to-guest ssh still work and the k3s API does not, on the iptables backend next to Cilium.
- First `devenv shell` in a new environment is 25 to 32 s of evaluation. Seeding a new home's `~/.cache/nix` from the host user's was not done: copying the live sqlite fetcher cache can corrupt it, and the cost looks like devenv's per-repo evaluation, not fetching. The empty `flake-registry` only removes the global registry fetch.

- 2026-11-11 `nc201`: on lenovo the guest is `Trusted: 1` on the host daemon, because the guest user is the host
  user and lenovo keeps that user trusted. The doc said otherwise; corrected. Untrusting needs a different guest uid
  or a host without a trusted login user; owner decision with the nested /proc one.
- 2026-11-11 `nc201`: host ssh key, gh token and OAuth token are bound into every guest, so "research only, do not
  push" is held by the brief, not the environment. A per-instance `credentials` subset would make it structural.
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

## Fixed

- Host reboot on acer (2026-11-12, `systemctl reboot` with one environment declared): system `running` with no failed units, `environments.slice` and the instance's limits back (7G pool, 2G reserved, 6G max, 3G swap), nix-daemon up, container starting 7 s into userspace, its agent idle in the host's Herdr at 15 s, home files kept, host store and shared `~/.cache/nix` mounted, first `devenv shell` in an existing clone 7.4 s. Rebooted again with a conversation in the agent: it came back in that conversation and recalled a token given before the reboot.
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
