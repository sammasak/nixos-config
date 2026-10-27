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

  x86 = inputs.deploy-rs.lib.x86_64-linux.activate;
  aarch64 = (deployLib "aarch64-linux").activate;

  mkNode = name: activate: profile: {
    hostname = name;
    profiles.system = {
      # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
      sshUser = "deploy";
      user = "root";
      path = activate.nixos config.flake.nixosConfigurations.${name};
      autoRollback = true;
      magicRollback = true;
      activationTimeout = 180;
      confirmTimeout = 30;
    } // profile;
  };
in
{
  flake.deploy.nodes = {
    lenovo = mkNode "lenovo" x86 { } // { hostname = "localhost"; };

    # False (the deploy-rs default too): building on acer, the sole k3s
    # worker, would I/O-storm the node mid-deploy. Build stays on lenovo.
    acer-swift = mkNode "acer-swift" x86 { remoteBuild = false; };

    # Only reachable in its Mon-Fri ~09:00-21:00 power window.
    msi-ms7758 = mkNode "msi-ms7758" x86 { remoteBuild = false; };

    # True, unlike acer: lenovo has no aarch64 builder, so the Pi builds its
    # own closure (untrusted lukas is enough: .drv and sources are CA paths).
    black-pi = mkNode "black-pi" aarch64 { remoteBuild = true; };

    # True for the same no-aarch64-builder reason; rf-lab keeps the closure
    # to cache hits plus text/symlink derivations, so 1 GiB is enough.
    naked-pi = mkNode "naked-pi" aarch64 { remoteBuild = true; };
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
