# deploy-rs push targets: one node per hosts-table entry; hostname and remoteBuild come from hosts.nix.
{ config, inputs, lib, ... }:
let
  # nixpkgs' deploy-rs binary is cached for aarch64; the flake's own would be
  # a Rust build on the Pi.
  deployLib =
    system:
    (import inputs.nixpkgs {
      inherit system;
      overlays = [
        inputs.deploy-rs.overlays.default
        (final: prev: {
          deploy-rs = {
            inherit (inputs.nixpkgs.legacyPackages.${system}) deploy-rs;
            inherit (prev.deploy-rs) lib;
          };
        })
      ];
    }).deploy-rs.lib;

  activateFor = {
    x86_64-linux = inputs.deploy-rs.lib.x86_64-linux.activate;
    aarch64-linux = (deployLib "aarch64-linux").activate;
  };

  # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
  pushAs = {
    sshUser = "deploy";
    user = "root";
    # The x86 nodes' activate (this pin) may leave a failed unit's generation while the client reports a
    # rollback (serokell/deploy-rs#411; the Pis' nixpkgs build is unread): after a failed deploy, compare
    # the target's `readlink /run/current-system` with its value before the deploy.
    autoRollback = true;
    magicRollback = true;
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
      sshOpts = [ "-o" "StrictHostKeyChecking=yes" ];
      profiles.system =
        pushAs
        // { path = activateFor.${host.pkgs.stdenv.hostPlatform.system}.nixos host; }
        // lib.optionalAttrs deploy.remoteBuild { remoteBuild = true; };
    };
in
{
  flake.deploy.nodes = lib.mapAttrs mkNode config.configurations.nixos;

  perSystem =
    { system, ... }:
    {
      # Unfiltered, the x86 check would need the aarch64 toplevel built on lenovo.
      checks = inputs.deploy-rs.lib.${system}.deployChecks (
        config.flake.deploy
        // {
          nodes = lib.filterAttrs (_: node: node.profiles.system.path.system == system) config.flake.deploy.nodes;
        }
      );
    };
}
