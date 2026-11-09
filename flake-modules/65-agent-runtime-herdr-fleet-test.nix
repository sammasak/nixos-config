{ config, lib, inputs, ... }:
{
  # #186 fleet monitoring: a lenovo-like coordinator sees two worker hosts' runtimes through
  # saved Herdr machines. A package, not a check, like the other agent-runtime VM tests -- the
  # QEMU boot runs on an explicit `nix build .#packages.x86_64-linux.agent-runtime-herdr-fleet-test`
  # (acer, heavy lock), out of nixos:qa.
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-herdr-fleet-test = import ../tests/agent-runtime-herdr-fleet.nix {
          inherit pkgs lib;
          skills = inputs.skills;
          registration = config.flake.nixosConfigurations.lenovo.config.home-manager.users.lukas.home.activation.herdrMachines.data;
        };
      };
    };
}
