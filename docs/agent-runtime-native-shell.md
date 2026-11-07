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
- **devenv shells** (`devenv.nix`/`devenv.yaml` imports) are not covered: rf-proto is a flake
  `mkShell`, and `native-shell.nix` refuses a non-mkShell devShell.
- **The `factum`/`llm-gateway` pins and the measured cold/warm host-side realization times** are
  follow-ups.
- **The devenv-platform `prepare` glue**, from a plan's `selected_environment`/`check_argv` to this
  template, waits on devenv-platform#117 (prepare detection, in review).
