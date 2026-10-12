# deploy-rs push targets. lenovo's hostname is localhost: deploy-rs is only
# ever invoked from lenovo itself, so lenovo's own deploy is a loopback
# self-push, used to prove the sudo/magic-rollback path before it is ever
# trusted against acer-swift, which has no BMC.
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
in
{
  flake.deploy.nodes = {
    lenovo = {
      hostname = "localhost";
      profiles.system = {
        # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
        sshUser = "deploy";
        user = "root";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos config.flake.nixosConfigurations.lenovo;
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 180;
        confirmTimeout = 30;
      };
    };

    acer-swift = {
      hostname = "acer-swift";
      profiles.system = {
        sshUser = "deploy";
        user = "root";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos config.flake.nixosConfigurations.acer-swift;
        # False (the deploy-rs default too): building on acer, the sole k3s
        # worker, would I/O-storm the node mid-deploy. Build stays on lenovo.
        remoteBuild = false;
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 180;
        confirmTimeout = 30;
      };
    };

    black-pi = {
      hostname = "black-pi";
      profiles.system = {
        sshUser = "deploy";
        user = "root";
        path = (deployLib "aarch64-linux").activate.nixos config.flake.nixosConfigurations.black-pi;
        # True, unlike acer: lenovo has no aarch64 builder, so the Pi builds its
        # own closure (untrusted lukas is enough: .drv and sources are CA paths).
        remoteBuild = true;
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 180;
        confirmTimeout = 30;
      };
    };
  };

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
