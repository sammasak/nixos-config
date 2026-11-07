# Native devenv/flake execution inside the nspawn runtime (devenv-platform#93)

The experiment: can a *real pinned native* devenv/flake shell be prepared and
exercised safely with the **existing** nspawn agent runtime
([nixos-config#169](https://github.com/sammasak/nixos-config/issues/169),
#144/#148/#152), without giving repository hooks host access or permitting
unbounded Nix writes? This is an offline, disposable-VM compatibility experiment
(it does not switch any live host). The proof is the nixosTest
`agent-runtime-devenv-native` (`tests/agent-runtime-devenv-native.nix`); the
pinned fixture/template is `tests/agent-runtime/devenv-native.nix`, shared with
the pure-eval check `checks.x86_64-linux.agent-runtime-devenv-native-eval`
(which runs in `nixos:qa`). No lifecycle, quota or admission code is copied,
forked or replaced — the test drives the shipped `agent-runtime-instance` tool
unchanged.

## Result

- **Mode (a) — host-realized pinned shell projected read-only: WORKS.** The
  selected devShell's toolchain (`gnumake`, `gcc`, `coreutils`) is realized on
  the trusted host and projected into the container through the read-only
  `/nix/store` bind and the manifest PATH. The devenv project check (`make check`,
  the fixture's `scripts.check.exec`) builds and runs a C program **inside** the
  guest with that toolchain. The devenv `enterShell`/project hooks run **only in
  the guest** (their markers appear in the writable workspace copy, never in the
  read-only projected source store path, and never on the host during
  preparation).

- **Mode (b) — cold guest-side Nix/devenv realization: UNSUPPORTED by this
  runtime, by design.** The container has **no Nix daemon socket**
  (`/nix/var/nix/daemon-socket/socket` absent), a **read-only `/nix/store`**, and
  **no network** (`--private-network`, only `lo`). A genuinely cold
  `nix build /workspace/fixture#devShells.x86_64-linux.default` therefore fails;
  the test records the exact command, its non-zero exit, and the structural
  reasons (`daemon_socket_present=no`, `store_writable=no`, `net_ifaces=lo`) to
  `output/mode-b.log`. The runtime never silently selects this backend. A
  private-store cold build would need a writable private store and a guest daemon
  that the runtime deliberately does not provide; that is left to a future slice
  only if a concrete need is demonstrated (per #93), not invented here.

## What the test asserts (the acceptance, mechanically)

- **Pinned metadata.** The tiny fixture is pinned as a *locked* source: its store
  path is the authority (assign.sh GC-roots it offline and never prefetches),
  `narHash` is the real NAR hash of that path (materialize recomputes and
  verifies it), and `rev` is a deterministic synthetic commit id (there is no
  upstream GitHub repo for an in-tree fixture). The eval check emits
  `pins.json` with `{rev, narHash, storePath}`; the in-guest run records the
  selected devShell and the projected toolchain versions to `output/toolchain.txt`.
- **Bounds.** Volumes are the runtime's five fixed-size ext4-on-loopback images
  (workspace/home/tmp/cache/output, each with a byte and inode budget). Filling
  the workspace hits `No space left on device` **inside** the instance while the
  host `/var/lib` growth stays bounded (asserted ≤ the image size).
- **Isolation.** Network and secrets are denied by default (only `lo`, no
  credential dir). A no-capability container root cannot write the store, remount
  `/nix/store` or `/`, mount a fresh tmpfs, `mknod`, touch `/proc/sys`, read
  `/proc/kcore`, rename the host, or nest a user namespace — every attempt is
  asserted to fail against disposable sentinels. All caps are zero, `NoNewPrivs=1`,
  `Seccomp=2`, and the guest uid maps above 1048576 (never host root).
- **One cgroup.** The run is a `systemd-run` transient unit with `Delegate=yes`;
  every build descendant stays under `agent-runtime-<id>.service`'s cgroup, which
  the test inspects directly.
- **Lifecycle.** A good run succeeds and exports a verifiable bundle; a broken
  source makes the project check fail **while the editing shell (projected
  toolchain) still works**; a SIGKILL mid-run is a definite `failed` outcome with
  a recovery bundle; teardown leaves nothing behind (no mounts, loops, units,
  machines, or state).
- **Measurements.** The test prints `DEVENV-NATIVE MEASURES` (cold/warm run
  wall-time, `runtimeUSec`, `memoryPeakBytes`, workspace disk bytes, and the
  projected-shell store-closure bytes). Host `/nix/store` growth across a warm run
  is ~0 because nothing is realized guest-side.

## Pinned revisions (sources captured)

| source | pin | devShell / toolchain | realized |
|---|---|---|---|
| tiny fixture | in-tree `tests/fixtures/devenv-native` (locked store path; see `pins.json`) | `devShells.x86_64-linux.default` = [gnumake gcc coreutils] | host-side in the test, projected into nspawn |
| factum | `inputs.factum` @ `5bb7fa304db7d8ae7d422e8d6356bf06b90d3b41` (flake.lock, `sha256-nuvKoO+Avhz21fetB3X9mJMcYcRpbqiBPTUht5Vo8IA=`) | rust-toolchain.toml → rust 1.99.0 (the rust-pilot template already projects this) | host-side (the `agent-runtime-pilot` path) |
| llm-gateway | pinned by rev in the devenv-platform portfolio; **not** a nixos-config flake input | its devShell (rust) is realized host-side with the same projection; realize with `nix build <llm-gateway>#devShells.x86_64-linux.default` | **operator/CI step** (not an input here; not built offline in this VM) |

factum's full closure is exercised by the existing `agent-runtime-pilot-test`
(a cold release build of its 175-crate graph inside nspawn, measured in
`docs/agent-runtime-pilot.md`); this experiment does not rebuild it. llm-gateway
is recorded with the exact realization command and left to the operator/CI,
since it is not a flake input of this repo and building it offline here is out of
the "smallest executable proof" scope.

## How to run

```
# the pure-eval gate (part of nixos:qa):
nix build .#checks.x86_64-linux.agent-runtime-devenv-native-eval
# the full VM experiment (heavy QEMU boot; acer heavy-work lock), prints MEASURES:
nix build .#packages.x86_64-linux.agent-runtime-devenv-native
```

## Conclusion (informs devenv-platform#96 and #91)

The existing nspawn runtime is sufficient for **native pinned devShell execution
via host realization + read-only projection** (mode a): a real devenv/flake
toolchain is prepared on the trusted host and exercised in a bounded, network-
and secret-denied, single-cgroup, non-root container, with hooks confined to the
guest. Cold guest-side realization (mode b) is not possible without weakening the
very boundaries the runtime enforces (a guest daemon or a writable/private store),
so #96 should build on mode (a): resolve and realize the devShell host-side (the
prepare:plan from #92 selects it), then project it — not attempt an in-guest
`nix develop`.
