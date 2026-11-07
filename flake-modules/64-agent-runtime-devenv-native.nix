{ lib, inputs, ... }:
{
  # devenv-platform#93: validate a real pinned native devShell inside the existing
  # nspawn runtime. A package (heavy QEMU boot), run explicitly like the other
  # agent-runtime VM tests: `nix build .#packages.x86_64-linux.agent-runtime-devenv-native`.
  # The pure-eval check below runs in `nixos:qa` (flake check): it proves the
  # fixture template is a locked (offline), network-off, credential-free, bounded
  # projection -- mode (a) -- without booting the VM.
  perSystem =
    { pkgs, system, ... }:
    let
      dn = lib.optionalAttrs (system == "x86_64-linux") (
        import ../tests/agent-runtime/devenv-native.nix {
          inherit pkgs lib;
          skills = inputs.skills;
        }
      );
    in
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-devenv-native = import ../tests/agent-runtime-devenv-native.nix {
          inherit pkgs lib;
          skills = inputs.skills;
        };
      };

      checks = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-devenv-native-eval =
          let
            ev = dn.evaluated;
            t = ev.manifestData.devenv-native;
            expect = cond: msg: lib.assertMsg cond "agent-runtime-devenv-native-eval: ${msg}";
          in
          assert expect (ev.hostPolicy != null) "the host policy renders";
          assert expect (t.policies.network == { egress = "none"; allow = [ ]; }) "mode (a): no egress";
          assert expect (t.policies.capabilities == [ ] && t.policies.privateSources == [ ]) "no credential, no private source";
          assert expect (t.sources.fixture.resolve == "lock") "the fixture is a locked source (resolved offline, never prefetched)";
          assert expect (t.sources.fixture.locked.rev == dn.fixtureRev) "the locked rev is the fixture's pinned commit";
          assert expect (t.sources.fixture.writable) "a writable copy so the project check and hooks run in the guest";
          assert expect (t.filesystem.mounts == [ ]) "no extra host mounts";
          assert expect (t.policies.resources.memoryMiB == 1024 && t.policies.resources.cpus == 1) "the small measured budgets";
          assert expect (t.filesystem.workspaceBudget.sizeMiB == 64 && t.filesystem.output.sizeMiB == 32) "bounded writable volumes";
          pkgs.runCommand "agent-runtime-devenv-native-eval" { nativeBuildInputs = [ pkgs.jq ]; } ''
            mkdir $out
            jq -S . ${ev.hostPolicy} > $out/host.json
            jq -S . ${ev.manifestDir}/devenv-native.json > $out/devenv-native.json
            # the pinned source metadata the experiment captures
            jq -nS --arg rev "${dn.fixtureRev}" --arg nar "${dn.fixtureNar}" --arg store "${dn.fixtureSrc}" \
              '{fixture: {rev: $rev, narHash: $nar, storePath: $store}}' > $out/pins.json
          '';
      };
    };
}
