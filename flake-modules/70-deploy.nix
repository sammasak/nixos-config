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
    name: profile:
    let
      host = config.flake.nixosConfigurations.${name};
    in
    {
      hostname = name;
      # the pinned key or nothing (modules/core/ssh-known-hosts.nix): no first-use trust from the deployer either
      sshOpts = [ "-o" "StrictHostKeyChecking=yes" ];
      profiles.system = pushAs // { path = activateFor.${host.pkgs.stdenv.hostPlatform.system}.nixos host; } // profile;
    };
in
{
  flake.deploy.nodes = {
    lenovo = mkNode "lenovo" { } // { hostname = "localhost"; };

    # True: lenovo, memory-constrained, has crashed building these closures; acer's
    # build I/O mid-deploy is the lesser risk to the cluster.
    acer-swift = mkNode "acer-swift" { remoteBuild = true; };

    # True for the same reason; only reachable in its Mon-Fri ~09:00-21:00 power window.
    msi-ms7758 = mkNode "msi-ms7758" { remoteBuild = true; };

    # True, unlike acer: lenovo has no aarch64 builder, so the Pi builds its
    # own closure (untrusted lukas is enough: .drv and sources are CA paths).
    black-pi = mkNode "black-pi" { remoteBuild = true; };

    # True for the same no-aarch64-builder reason; rf-lab keeps the closure
    # to cache hits plus text/symlink derivations, so 1 GiB is enough.
    naked-pi = mkNode "naked-pi" { remoteBuild = true; };
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
