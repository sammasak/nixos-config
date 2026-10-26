# nix-audit pilot

Advisory, report-only nix-audit on lenovo, acer-swift and msi-ms7758. Nothing here blocks a
switch, deploy or CI run. Making the gate blocking needs a separate owner decision. The
operator guide, the exit codes and the pilot record format are upstream:
`docs/USER-GUIDE.md` and `docs/PILOT.md` in sammasak/nix-audit.

## Pin

`inputs.nix-audit` is a `flake = false` input pinned to the 0.1.0-rc1 release commit
`38789c530998164335637c6b6982b5ddc9e0fda1`. The Nix client fetches it over ssh with your
key, and `flake.lock` pins rev and narHash, so no ssh runs inside the build sandbox and
nothing has to be prefetched. A flake input has no `.git`, so the package passes the locked
rev as `NIX_AUDIT_DECLARED_REVISION`. Update it with `just bump nix-audit` after choosing a
reviewed nix-audit commit.

`modules/programs/cli/nix-audit.nix` installs `nix-audit`, `grype` and `vulnix` for the
user. The example policy ships at `$(dirname $(readlink -f $(command -v nix-audit)))/../share/nix-audit/policy.toml`.

## Activation checks

```sh
command -v nix-audit && nix-audit --version     # nix-audit 0.1.0 (38789c530998, declared by the build)
nix flake metadata ~/nixos-config --json | jq -r '.locks.nodes["nix-audit"].locked.rev'   # the same commit
readlink -f "$(command -v nix-audit)"           # inside this host's Home Manager profile
command -v grype vulnix && grype db status | grep -E 'Built|Status'
nix-audit scan /run/current-system --no-scan    # exit 0, inventory only
systemctl list-units --all | grep -ci nix-audit # 0: no service, no timer
```

Accept the binary only when its full `producer.revision` (`nix-audit scan … --json`)
is the reviewed release commit and equals the locked rev.

## Comparing a candidate

```sh
just audit-candidate acer-swift            # on lenovo: candidate built here, baseline read over ssh
just audit-candidate lenovo local          # this machine's own running system
```

The recipe builds the candidate without activating it and scans the running system and the
candidate under `flock /tmp/$(hostname)-heavy-work.lock`. It then gates the pair. If that
gate exits 3, it also runs a grype-only gate. Evidence goes to
`~/nix-audit-pilot/<date>-<host>-<rev>/`, which stays private on that host, and the recipe
always exits 0. acer-swift and msi are deployed from lenovo, which holds their derivations,
so run their comparisons on lenovo. vulnix needs the closure's `.drv` files in the local
store: on a target that did not build its own system, vulnix fails (exit 3) and only a
grype-only comparison is possible. If the running system is no longer in lenovo's store, the
recipe says so and stops.

## Rollback

Revert this change, or drop a host from the `lib.elem` list in
`flake-modules/40-outputs-nixos.nix`, then switch or deploy as usual. nix-audit installs no
service, hook or timer, and removing it changes no system it inspected. It writes:
- its `--json-out` files and `~/nix-audit-pilot`;
- the grype and vulnix databases in `~/.cache`;
- the gcroot of each run's `candidate` out-link, which keeps that closure alive so it can be
  the next baseline.

Delete old `~/nix-audit-pilot/*/candidate` links to release those closures.
