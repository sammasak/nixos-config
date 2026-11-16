# deploy-rs push targets: one node per hosts-table entry; hostname and remoteBuild come from hosts.nix.
{
  config,
  inputs,
  lib,
  ...
}:
let
  # activate-rs runs on the target, patched with serokell/deploy-rs#412 (a failed unit really rolls back); drop the
  # override when the pin contains the fix. The patched build is not cached: on aarch64 it builds on black-pi, and
  # naked-pi (1 GiB) needs it copied in before its deploy (CLAUDE.md).
  activate =
    system:
    (import inputs.nixpkgs {
      inherit system;
      overlays = [
        inputs.deploy-rs.overlays.default
        (final: prev: {
          deploy-rs = prev.deploy-rs // {
            deploy-rs = prev.deploy-rs.deploy-rs.overrideAttrs (o: {
              patches = (o.patches or [ ]) ++ [ ../pkgs/patches/deploy-rs-412-rollback-before-cancel.patch ];
            });
          };
        })
      ];
    }).deploy-rs.lib.activate;

  activateFor = lib.genAttrs [
    "x86_64-linux"
    "aarch64-linux"
  ] activate;

  # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
  pushAs = {
    sshUser = "deploy";
    user = "root";
    autoRollback = true;
    magicRollback = true;
    # covers a failed activation plus the re-activation of the previous generation
    activationTimeout = 180;
    confirmTimeout = 30;
  };

  mkNode =
    name:
    { deploy, ... }:
    let
      host = config.flake.nixosConfigurations.${name};
    in
    {
      inherit (deploy) hostname;
      # the pinned key or nothing (modules/core/ssh-known-hosts.nix): no first-use trust from the deployer either
      sshOpts = [
        "-o"
        "StrictHostKeyChecking=yes"
      ];
      profiles.system =
        pushAs
        // {
          path = activateFor.${host.pkgs.stdenv.hostPlatform.system}.nixos host;
        }
        // lib.optionalAttrs deploy.remoteBuild { remoteBuild = true; };
    };
in
{
  flake.deploy.nodes = lib.mapAttrs mkNode config.configurations.nixos;

  perSystem =
    { system, ... }:
    {
      # One pair of checks per node: a check over several nodes holds all their hosts in one evaluator,
      # which does not fit a 4G cap. Unfiltered, the x86 checks would need the aarch64 toplevels built on lenovo.
      checks = lib.concatMapAttrs (
        name: node:
        lib.mapAttrs' (check: lib.nameValuePair "${check}-${name}") (
          inputs.deploy-rs.lib.${system}.deployChecks (config.flake.deploy // { nodes.${name} = node; })
        )
      ) (lib.filterAttrs (_: node: node.profiles.system.path.system == system) config.flake.deploy.nodes);
    };
}
