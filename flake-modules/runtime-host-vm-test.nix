{
  config,
  lib,
  fleetModules,
  ...
}:
{
  # Checks as well as packages: `nix flake check` and the pre-push gate (msi or acer) boot them, and a built one is a
  # cache hit. The packages stay for `just role-vm-test` and its .broken variant.
  perSystem =
    { pkgs, system, ... }:
    let
      vmTests = {
        dev-env-reset-vm = import ../tests/dev-env-reset-vm.nix {
          inherit pkgs fleetModules;
          inherit (config.configurations.nixos.msi-ms7758) roles;
          roleModules = with config.flake.modules.nixos; [
            role-base
            role-runtime-host
          ];
        };
        socket-rebind-vm = import ../tests/socket-rebind-vm.nix { inherit pkgs; };
        post-deploy-check-vm = import ../tests/post-deploy-check-vm.nix { inherit pkgs; };
        rebuild-trigger-vm = import ../tests/rebuild-trigger-vm.nix { inherit pkgs; };
        runtime-host-role-vm = import ../tests/runtime-host-role-vm.nix {
          inherit pkgs fleetModules;
          inherit (config.configurations.nixos.msi-ms7758) roles;
          roleModules = with config.flake.modules.nixos; [
            role-base
            role-runtime-host
          ];
        };
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages = vmTests;
      checks = vmTests;
    };
}
