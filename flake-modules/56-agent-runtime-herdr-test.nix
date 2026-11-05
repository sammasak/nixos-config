{ lib, inputs, ... }:
{
  # A package, not a check, like 55-agent-runtime-test.nix: the QEMU boot runs on
  # an explicit `nix build .#packages.x86_64-linux.agent-runtime-herdr-test` (acer, heavy lock).
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-herdr = import ../modules/agent-runtime/herdr { inherit pkgs; };
        agent-runtime-herdr-test = import ../tests/agent-runtime-herdr.nix {
          inherit pkgs lib;
          skills = inputs.skills;
        };
        # two nodes: a coordinator reaching the runtime host through a saved Herdr machine
        agent-runtime-herdr-machines-test = import ../tests/agent-runtime-herdr-machines.nix {
          inherit pkgs lib;
          skills = inputs.skills;
        };
      };
    };
}
