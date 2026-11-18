# nspawn environments: time to shell and gate timing (November 2026)

Moved unchanged from `docs/environments-feedback.md` on 2026-11-18: dated measurements, not ledger lines.

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
