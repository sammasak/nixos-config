{
  config,
  lib,
  fleetModules,
  ...
}:
{
  # Checks only: nixos:flake-check evaluates each package in a process of its own, so these tests as packages too would
  # be evaluated twice.
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
        execution-pool-vm = import ../tests/execution-pool-vm.nix {
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
      checks = vmTests;
      # Opt-in: the scheduled gate evaluates but does not boot packages. Compare before replacing the VM check.
      packages.post-deploy-check-nspawn = import ../tests/post-deploy-check-vm.nix {
        inherit pkgs;
        nativeContainer = true;
      };
    };
}
