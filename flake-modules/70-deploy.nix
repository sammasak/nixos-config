# deploy-rs push targets. lenovo's hostname is localhost: deploy-rs is only
# ever invoked from lenovo itself, so lenovo's own deploy is a loopback
# self-push, used to prove the sudo/magic-rollback path before it is ever
# trusted against acer-swift, which has no BMC.
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

  x86 = activate "x86_64-linux" true;
  # Still serokell/deploy-rs#411 (a failed unit is not really rolled back), so the post-deploy
  # check is mandatory on the Pis until a patched aarch64 build is evidenced (#297).
  aarch64 = activate "aarch64-linux" false;

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
