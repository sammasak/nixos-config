{
  config,
  lib,
  fleetModules,
  ...
}:
{
  # A package, not a check, as rf-hwsim-dataplane: `nix flake check` evaluates it
  # but builds no package, so the QEMU boot runs only from `just role-vm-test`.
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        runtime-host-role-vm = import ../tests/runtime-host-role-vm.nix {
          inherit pkgs fleetModules;
          inherit (config.configurations.nixos.msi-ms7758) roles;
          roleModules = with config.flake.modules.nixos; [
            role-base
            role-runtime-host
          ];
        };
      };
    };
}
