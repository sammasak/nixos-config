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

  # Key-only, lenovo-only login with passwordless sudo (homelab/deploy-target.nix).
  pushAs = {
    sshUser = "deploy";
    user = "root";
    autoRollback = true;
    magicRollback = true;
    activationTimeout = 180;
    confirmTimeout = 30;
  };

  mkNode = name: mkNodeFrom config.flake.nixosConfigurations.${name} name;
  mkNodeFrom =
    nixos: name: activate: profile:
    let
      runtime = nixos.config.sam.agentRuntime;
    in
    {
      hostname = name;
      # the pinned key or nothing (modules/core/ssh-known-hosts.nix): no first-use trust from the deployer either
      sshOpts = [ "-o" "StrictHostKeyChecking=yes" ];
      # the substrate before the templates: the template profile's activation checks the substrate
      profilesOrder = [ "system" ] ++ lib.optional runtime.host.enable "agent-runtime";
      profiles = {
        system = pushAs // { path = activate.nixos nixos; } // profile;
      }
      // lib.optionalAttrs runtime.host.enable {
        # templates only, no host switch (#140): `deploy .#<node>.agent-runtime` updates them alone
        agent-runtime = pushAs // {
          path = activate.custom ((config.flake.lib.agentRuntime { inherit (nixos) pkgs; }).templateProfile {
            agentRuntime = runtime;
          }) "$PROFILE/bin/agent-runtime-templates-activate";
          profilePath = "/nix/var/nix/profiles/agent-runtime/templates";
        } // lib.filterAttrs (n: _: n == "remoteBuild") profile;
      };
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
    { system, pkgs, ... }:
    {
      # Unfiltered, the x86 check would need the aarch64 toplevel built on lenovo.
      checks = inputs.deploy-rs.lib.${system}.deployChecks (
        config.flake.deploy
        // {
          nodes = lib.filterAttrs (_: node: node.profiles.system.path.system == system) config.flake.deploy.nodes;
        }
      )
      // lib.optionalAttrs (system == "x86_64-linux") {
        # The real lenovo and acer-swift with the substrate on and one template (#140): deploy-rs's
        # schema and activation checks over both profiles, and at evaluation the claim that
        # a template change moves the template profile but not the host's system.
        agent-runtime-deploy-compat =
          let
            hosts = [ "lenovo" "acer-swift" ];
            enabled =
              name: version:
              config.flake.nixosConfigurations.${name}.extendModules {
                modules = [
                  (import ../tests/agent-runtime/deploy-templates.nix { inherit (inputs) skills; inherit version; })
                  { sam.agentRuntime.host = { enable = true; eligibleTemplates = [ "tiny" ]; }; }
                ];
              };
            node = version: name: mkNodeFrom (enabled name version) name x86 { };
            drv = version: name: profile: (node version name).profiles.${profile}.path.drvPath;
            checks = inputs.deploy-rs.lib.${system}.deployChecks { nodes = lib.genAttrs hosts (node 1); };
            system1 = map (n: drv 1 n "system") hosts;
            templates1 = map (n: drv 1 n "agent-runtime") hosts;
          in
          assert lib.assertMsg (system1 == map (n: drv 2 n "system") hosts) "agent-runtime: a template change moved a host's system profile";
          assert lib.assertMsg (templates1 != map (n: drv 2 n "agent-runtime") hosts) "agent-runtime: a template change did not move the template profile";
          pkgs.runCommand "agent-runtime-deploy-compat" { } ''
            echo "deployChecks: ${checks.deploy-schema} ${checks.deploy-activate}" > $out
            echo "system (unchanged by templates): ${toString (map builtins.unsafeDiscardStringContext system1)}" >> $out
            echo "agent-runtime v1: ${toString (map builtins.unsafeDiscardStringContext templates1)}" >> $out
          '';
      };
    };
}
