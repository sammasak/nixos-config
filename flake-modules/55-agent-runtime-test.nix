{ lib, inputs, ... }:
{
  # A package, not a check, for the same reason as 50-rf-hwsim-test.nix: the
  # QEMU boot stays out of nixos:qa and runs on an explicit
  # `nix build .#packages.x86_64-linux.agent-runtime-nspawn` (acer, heavy lock).
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-nspawn = import ../tests/agent-runtime-nspawn.nix {
          inherit pkgs lib;
          rfProto = inputs.rf-proto;
          skills = inputs.skills;
        };
      };
    };
}
