# Native Nix shell in an agent-runtime instance (devenv-platform#93, mode (a))

Can a pinned repository's own devShell be prepared and used inside the existing nspawn runtime,
without the repository's hooks reaching the host and without Nix writes from the instance? This is the
smallest executable proof. It uses mode (a): the shell is realized on the host and the instance only
reads it.

## How

- **`modules/agent-runtime/native-shell.nix`** evaluates the repository's `flake.nix` against **its own
  `flake.lock`**, not nixos-config's inputs.
  - Every lock node is fetched with `builtins.fetchTree` from its locked attributes. This is pure,
    narHash-pinned, and follows `follows`.
  - It builds the selected `devShells.<system>.<name>`. Building a `pkgs.mkShell` writes its build
    environment to `$out`.
  - That environment, minus the builder-only variables `nix develop` also drops (HOME, TMPDIR, PWD,
    `out`, …), is the instance's shell: a file of `declare -x` lines.
  - Its closure is the shell's tools, in the host store.
  - Anything that is not a `mkShell` devShell fails evaluation with that reason.
- **`modules/agent-runtime/templates/native-shell.nix`** is the template, on `sammasak/rf-proto` at the
  flake's pinned rev. `native-shell-run [--passes N]`:
  1. sources the env file;
  2. evaluates the shell's `shellHook`, inside the instance only;
  3. runs rf-proto's gate (`cargo fmt --all --check`, `cargo clippy --all-targets --offline --locked -- -D warnings`, `cargo test --offline --locked`);
  4. writes `steps.jsonl` (argv, exit, ms per pass), `versions.json`, `shell.json`, `result.json` (volume MiB and inodes) and `SHA256SUMS` to `/output`.
- **The instance** gets the store read-only through the runtime's existing `/nix/store` bind. It has no
  nix on PATH, no daemon socket, no network (`network.allow` null) and no credential. Its resources
  are bounded: 2 CPUs, 2048 MiB, 512 tasks, 20 min, and quota'd volumes.

Provenance for rf-proto `89e08d2` (`shell.json`):
- `devShells.x86_64-linux.default` = `/nix/store/40ladp3…-nix-shell`, the same path rf-proto's own
  `nix build .#devShells.x86_64-linux.default` gives;
- its nixpkgs lock is `26f4107e`;
- the env closure is 90 paths, 2.9 GB NAR (the shell includes rust-analyzer);
- it was evaluated by nix 2.34.9.

## Evidence

`nix build .#packages.x86_64-linux.agent-runtime-native-shell-test` (`tests/agent-runtime-native-shell.nix`) is
a QEMU VM. Its subtests:

1. **The instance reads the host-realized shell.** There is no nix, no socket and no network, and
   the store and a sentinel are unwritable. An append to a store sentinel, a store create, and a
   remount of `/nix/store` or `/` rw are all refused. Before sourcing, there is no `cargo` on PATH;
   after it, the shell's `cargo`.
2. **The repository's own gate runs inside the instance with the pinned shell.** A cold then a warm
   pass, all exit 0. Seen from the host during the build, every `cargo`/`rustc`/`clippy-driver` is in
   `agent-runtime-gate.service`'s cgroup.
3. **A broken source.** A model-free fixture adds a syntax error. The editing shell still works
   (`cargo --version`), every gate step fails on the source, and the export carries the edit.
4. **Clean teardown.** No mounts, units or state remain, the VM store's path count is unchanged
   (no instance wrote to it), and the sentinel's sha256 is unchanged.

## Not covered here

- **Mode (b), guest-side cold realization** with a private store and bounded writes, is not attempted.
- **The fixture-level Devenv projection proof** runs with
  `scripts/test-agent-runtime-devenv-projection.sh` on x86_64-linux. It evaluates the fixture's
  committed `devenv.lock`, captures `devenv print-dev-env --json` and its configured check without
  entering the host shell, and launches both Devenv evaluations with an allowlisted environment
  and isolated temporary home. A regression fixture proves `builtins.getEnv` cannot capture a
  parent-process variable into the projection. Nix evaluation itself is not sandboxed from host
  files, so this preparation path remains for trusted pinned repositories. It sanitizes the
  generated environment and builds a QEMU test which runs
  that environment, imported configuration, `enterShell`, and the check inside the existing
  nspawn instance. The negative case rejects a host-local profile before evaluating the hook or
  check. The fixture asserts its lockfile stays unchanged and the host hook marker stays absent.
- **The real-project Devenv acceptance test** runs with
  `scripts/test-agent-runtime-llm-gateway-devenv-projection.sh`. It prepares the committed Devenv
  lock from the exact `sammasak/llm-gateway` pin in `flake.lock`, captures the project's generated
  environment and `rust:test` task without entering its host shell, then runs that task in the
  existing nspawn instance with egress denied and Cargo in offline mode. The temporary writable
  guest checkout gets Git metadata because the project's `enterShell` uses Git. The environment's
  referenced store paths, Cargo vendor tree, and task executable are pinned into the guest closure.
  At the recorded pin, all 419 tests passed; `destroy --discard` then left no runtime mounts, unit,
  state directory, machine registration, or loop device. The full `nixos:qa` gate is still pending.
- **Factum acceptance** is covered by the open nixos-config#194 follow-up. At parent commit
  `aab678194700b4b073860b5ad461bcab914b4b03`, the targeted NixOS guest run consumed a fresh typed
  request for Factum PR #38, matched its captured Rust `1.99.0` against guest `rustc`, and passed
  the exact `cargo test --locked` check in 1,586.28 seconds. Cancellation, deliberate missing-target
  failure, verified success/cancellation/failure bundles, no-replay retry, artifact persistence,
  and teardown assertions also passed. The test-only `CARGO_PROFILE_TEST_DEBUG=0` setting keeps
  this full suite within the unchanged 8 GiB runtime cap. At follow-up head
  `f1b2ee9f4b984ab343f860c879d1308d34f0a016`, the isolated broken-source case passed in 23.88
  seconds: it edits `crates/facts-domain/src/lib.rs` inside nspawn, confirms `cargo` still runs,
  observes `cargo fmt --all --check` fail on the edited source, and verifies an exported failure
  bundle contains the patch. Run that focused case with
  `AGENT_RUNTIME_FACTUM_BROKEN_ONLY=1 AGENT_RUNTIME_FACTUM_REQUEST_JSON=/path/to/request.json bash scripts/test-agent-runtime-factum-devenv-projection.sh`;
  omit `BROKEN_ONLY` to run the full acceptance suite. The full `nixos:qa` gate and formal PR review
  remain pending.
- **Typed `devenv-platform/execution-request` consumption** is covered by the focused follow-up
  on `feat/96-runtime-request-consumer`: a ready request must match the pinned repository, commit,
  project root, target system and environment kind, then verifies that the request's lockfile blob
  matches the materialized pinned checkout before its `check.argv` is executed inside nspawn. It
  compares a captured `rust` version against `rustc --version` after guest activation and before
  the check, then records the declared and observed versions in `result.json`. The guest test
  covers a matching version, a mismatch that prevents the check, blocked requests and forged
  lockfile hashes. The fresh Factum request described above exercises the same consumer with its
  evidence-bound Rust tool version.
- For an assigned instance, `agent-runtime-instance start ID --request REQUEST.json -- PROGRAM [ARG...]`
  binds a stable copy of the ready request read-only at `/etc/agent-runtime/execution-request.json`
  and records its SHA-256 in `started.json`. Before launch, the lifecycle checks the request's
  repository and exact commit against the assigned source. The Devenv runner merges the request
  with its separately prepared environment JSON in guest tmpfs, verifies the pinned `devenv.lock`
  blob, then executes the request argv directly. The focused VM test covers successful handoff,
  source mismatch and blocked-request refusal without starting a unit.
- **Plan-to-request glue** is implemented in open devenv-platform#118 at
  `db50f6f1b73087255540687db9e863c13fd3d268`. It carries evidence-bound declared tool versions into
  ready requests. The Factum request above was generated from a persisted `prepare:plan` result and
  consumed the captured Rust version in the guest. PR review and aggregate quality gates remain
  pending.
