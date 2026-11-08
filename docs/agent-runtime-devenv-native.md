# Devenv configuration in the nspawn runtime (devenv-platform#93)

This test evaluates a pinned Devenv project and executes its configured check
inside the existing agent-runtime nspawn guest. It does not realize the full
Devenv-generated shell environment yet; the guest toolchain is explicitly
listed from the same pinned nixpkgs packages as the fixture.

## Fixture and execution

`tests/fixtures/devenv-native` requires Devenv `2.4.0`. Its `devenv.lock` pins
the Devenv module input to `9655d320b8f9df74dbecf681f52a7334574606c3` and
nixpkgs to `fe13242281a67641c0102cdb1087f0ebe586c7df`. The YAML imports
`./tooling`; that module exports `DEVENV_IMPORT_MARKER`.

The test derivation copies the fixture to a temporary project and, offline,
uses Devenv to evaluate `scripts.check.exec` and
`env.DEVENV_IMPORT_MARKER`. It asserts both are present and that the imported
marker has the expected value. This evaluation does not enter the shell or run
project hooks on the host. The VM runner loads the evaluated script and marker,
sets `DEVENV_ROOT` to the guest's writable `/workspace/fixture`, then executes
the exact script there. The script checks the imported marker, writes
`.devenv-script-ran`, and runs `make check`. The harness does not create that
Devenv-defined marker.

The test fails during config preparation if `devenv.nix` or the YAML import is
removed: the script extraction or imported-marker assertion fails. A mutation
probe from the published fixture also confirmed that removing either the YAML
import or `devenv.nix` makes the corresponding Devenv evaluation exit non-zero.

## Runtime behavior and limits

Mode (a) runs the configured check with the fixture's explicitly projected
`gnumake`, `gcc` and `coreutils` inside the guest. The existing admission,
network and credential denial, read-only store, capability/seccomp boundary,
resource quotas, broken-source behavior, lifecycle, recovery and cleanup tests
remain in the VM suite.

Mode (b) attempts `devenv --offline … shell -- true` from the fixture root
inside nspawn. The runtime has no Nix daemon socket, exposes `/nix/store`
read-only and allows only loopback networking. Nix falls back to a private
store under the guest's quota'd home and fails while importing the locked
nixpkgs tree with `No space left on device`. The command and structural reasons
are recorded in `mode-b.log`; the test checks the failure is not caused by a
missing project file. No host Nix socket or writable host store is exposed.

This is configuration/script acceptance evidence, not complete #93 closure.
Remaining work includes capturing and projecting the complete Devenv-generated
environment, exercising the requested Factum and llm-gateway pins through this
Devenv path, and retaining the documented cold-guest limitation.

## Validation

Run the focused VM package under Acer's heavy-work lock:

```sh
flock /tmp/acer-swift-heavy-work.lock nix build --no-link --print-build-logs .#packages.x86_64-linux.agent-runtime-devenv-native
```

The published commit `9342aae534d44a40de1a90567bdc7ce6170869cc` passed the
positive guest check and existing runtime tests. Follow-up commit `91f5f00`
corrects the cold-activation probe to run from the fixture root; the focused VM
build also passed with that correction. Full `nixos:qa` was not run and remains
pending.
