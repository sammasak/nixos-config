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
- The host user's uid is assumed 1000 (mutableUsers, no declared uid); `sshKey` and `ghHostsFile` are home files whose existence only shows at container start.

## Fixed

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
