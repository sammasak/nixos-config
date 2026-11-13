# deploy-rs push targets. lenovo's hostname is localhost: deploy-rs is only
# ever invoked from lenovo itself, so lenovo's own deploy is a loopback
# self-push, used to prove the sudo/magic-rollback path before it is ever
# trusted against acer-swift, which has no BMC.
{ config, inputs, lib, ... }:
let
  # activate-rs runs on the target, so every node's profile needs the patched build; on the Pis
  # that is a Rust build there, as nothing caches it.
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

  x86 = activate "x86_64-linux";
  aarch64 = activate "aarch64-linux";

  # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
  pushAs = {
    sshUser = "deploy";
    user = "root";
    autoRollback = true;
    magicRollback = true;
    activationTimeout = 180;
    confirmTimeout = 30;
  };

  mkNode =
    name: activate: profile:
    {
      hostname = name;
      # the pinned key or nothing (modules/core/ssh-known-hosts.nix): no first-use trust from the deployer either
      sshOpts = [ "-o" "StrictHostKeyChecking=yes" ];
      profiles.system = pushAs // { path = activate.nixos config.flake.nixosConfigurations.${name}; } // profile;
    };
in
{
  flake.deploy.nodes = {
    lenovo = mkNode "lenovo" x86 { } // { hostname = "localhost"; };

    # True: lenovo, memory-constrained, has crashed building these closures; acer's
    # build I/O mid-deploy is the lesser risk to the cluster.
    acer-swift = mkNode "acer-swift" x86 { remoteBuild = true; };

    # True for the same reason; only reachable in its Mon-Fri ~09:00-21:00 power window.
    msi-ms7758 = mkNode "msi-ms7758" x86 { remoteBuild = true; };

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
