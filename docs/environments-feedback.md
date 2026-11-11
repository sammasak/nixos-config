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
- The hand-over brief is typed by hand; the coordinator does not yet check for an existing PR or build the brief.

## Fixed

- Quitting the agent dropped the pane to the host shell: the session now ends in a shell inside the environment (`modules/workers/default.nix`, `remoteCommand`).
- First acer environment booted without DNS (host `resolv.conf` empty mid-deploy): the container waits for a nameserver before starting.
- herman#5 was handed out although PR #34 already implemented it; the agent caught it. Step 1 of the process now checks for an open PR.
- The brief named `CLAUDE.md`, which herman does not have: briefs name no file, the agent finds the repo's guidance.
- `nixos:worker-permissions-test` read `spawn.nix` from the skills input and a numbered container; it now checks the workers module and a probe instance that replaces the committed ones.
