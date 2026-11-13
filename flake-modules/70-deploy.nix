# deploy-rs push targets: one node per hosts-table entry; hostname and remoteBuild come from hosts.nix.
{ config, inputs, lib, ... }:
let
  # activate-rs runs on the target. patched: serokell/deploy-rs#412, tracking #297; drop the
  # override when the pin contains the fix. Unpatched is nixpkgs' binary, cached for aarch64.
  activate =
    system: patched:
    (import inputs.nixpkgs {
      inherit system;
      overlays = [
        inputs.deploy-rs.overlays.default
        (final: prev: {
          deploy-rs = prev.deploy-rs // {
            deploy-rs =
              if patched then
                prev.deploy-rs.deploy-rs.overrideAttrs (o: {
                  patches =
                    (o.patches or [ ])
                    ++ [ ../pkgs/patches/deploy-rs-412-rollback-before-cancel.patch ];
                })
              else
                inputs.nixpkgs.legacyPackages.${system}.deploy-rs;
          };
        })
      ];
    }).deploy-rs.lib.activate;

  activateFor = {
    x86_64-linux = activate "x86_64-linux" true;
    # Still serokell/deploy-rs#411 (a failed unit is not really rolled back), so the post-deploy
    # check is mandatory on the Pis until a patched aarch64 build is evidenced (#297).
    aarch64-linux = activate "aarch64-linux" false;
  };

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
