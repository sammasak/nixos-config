# Shared Nix builds: G1 baseline (#200)

Measured on acer-swift in the `nc200` nspawn environment, 2026-11-11, nix 2.34.9, x86_64-linux,
`cores = 0`, `max-jobs = 8`, `sandbox = true`, `require-sigs = true`, substituters `cache.nixos.org` and
`nix-community.cachix.org`. The environment shares the host store read-only through the host daemon, so
the host's store was never purged and nothing was configured or deployed. This is evidence for the D1
owner gate, not a decision.

## Frozen inputs

| Fixture | Source | Rev | Command |
|---|---|---|---|
| 1 rust-service | `sammasak/devenv-platform` `examples/rust-service` | `aceadbb` (the rev nixos-config's `flake.lock` pins; remote HEAD is `de627ba`) | `devenv build outputs.rust-service` |
| 2 rf-proto native shell | `sammasak/rf-proto` | `89e08d2` (HEAD) | `nix build --no-link .#devShells.x86_64-linux.default` |

Fixture 2's test (`agent-runtime-native-shell`) was removed in #210; its doc survives in
`git show 5a40362^:docs/agent-runtime-native-shell.md`. The store path still reproduces: `40ladp3…-nix-shell`.

## Results

| | Fixture 1 | Fixture 2 |
|---|---|---|
| Cold (path absent from the host store) | 35.9 s, devenv eval plus a local build of the crate, 656 MB RSS (n=1) | 74.9 s, 74 paths substituted from cache.nixos.org (811.7 MiB download, 2.7 GiB unpacked) and one local build, 43 MB RSS (n=1) |
| Warm | 6.2, 2.9, 1.6 s (devenv eval only) | 0.30, 0.34, 0.29 s |
| Build of the crate alone (`nix build --rebuild`, n=3) | 2.10, 1.97, 1.92 s | none |
| `nix eval` of the derivation | not separated | 15.0 s cold (fetches the nixpkgs source), 0.73 and 0.67 s warm |
| Closure | 7 paths, 139.7 MB NAR; the output is 0.6 MB, the rest is glibc and gcc libs | 89 paths, 2.90 GB NAR |
| Substitution | not recorded by devenv | 74 of 75 paths (98.7%) from the public cache; the one local build is the `mkShell` |
| Host store growth, cold | not isolated | about 2.8 GB on a shared filesystem (noisy) |

## What this shows

- Neither fixture has a not-publicly-cached path that is expensive to build. Fixture 1's crate builds in
  about 2 s and its closure is glibc and gcc libs; fixture 2 is 98.7% public-cache hits. Repeated
  realization of these fixtures is bounded by download, not compilation, so a LAN cache (C) or
  a builder (B) has little to remove.
- The one evidenced expensive duplicate is `cargo-semver-checks-0.50.0` (1465 s on lenovo, 678 to 2174 s on
  acer, 404 on both public caches; #109), which is not one of the two fixtures. Adding it is the owner's call.

## Unmeasured

- Three cold repetitions: a path can be cold once per host store, and purging the shared host store is out of scope.
  Cold is n=1 for both fixtures.
- Repeat on another host, deploy-rs transfer bytes lenovo to acer, activation and application-ready time.
- Fixture 1's cache hit ratio, and its memory peak split between eval and build.
- Store inode change and GC roots; the filesystem is shared, so deltas are not attributable.

## D1

Not selected here. `KEEP A`, `POC B`, `POC C` or `DEFER` is the owner's choice in #200.
