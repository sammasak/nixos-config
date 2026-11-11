# Environment feedback ledger

What working real issues in the nspawn environments (`docs/nspawn-workers.md`)
taught, one line each. `fixed` names the change; `open` is a gap to close.
Append; move a line to fixed when its change lands.

## Open

- msi environments have no `gh` login (acer binds the host's `hosts.yml`): the agent cannot read issues or open PRs, the issue text is copied in and the PR opened from lenovo. Needs a GitHub token bound into every environment.
- Declaring an environment is a nixos-config commit, and every push runs the full `nixos:qa` (about 20 minutes, only safe from msi). Too slow for routine add/remove; instances are deployed from uncommitted edits meanwhile.
- A second `exit` in an environment's pane (from the shell left after the agent quits) returns the pane to the host shell.
- No host reboot test of environment recovery; only a container restart was exercised.
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
- Needs runtime check: a `memory`/`cpu` change applies live at the daemon-reload with no container restart (`systemctl show container@<name> -p MemoryMax` before and after, uptime unchanged).
- `blockedNetworks` (forward drop to the LAN, DNS excepted) is wired but off: needs a runtime check that GitHub, DNS and host-to-guest ssh still work and the k3s API does not, on the iptables backend next to Cilium.
- First `devenv shell` in a new environment is 25 to 32 s of evaluation. Seeding a new home's `~/.cache/nix` from the host user's was not done: copying the live sqlite fetcher cache can corrupt it, and the cost looks like devenv's per-repo evaluation, not fetching. The empty `flake-registry` only removes the global registry fetch.

## Fixed

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
