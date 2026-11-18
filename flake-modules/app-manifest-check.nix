# App manifest admission (lib/app-manifest) over its fixtures, against the facts only host evaluations give: the names
# the edge serves and each host's sops secret names; sam.fleet itself it reads lib-only. No host imports
# lib/app-manifest, so no toplevel depends on it, and its source here is those files alone.
{ config, lib, ... }:
let
  systems = map (c: c.config) (lib.attrValues config.flake.nixosConfigurations);
  edge = lib.findFirst (
    c: c.networking.hostName == c.sam.fleet.edge
  ) (throw "app-manifest-check: no host is sam.fleet.edge") systems;
  hostFacts = {
    edgeNames = lib.unique (
      lib.concatMap (
        n:
        let
          m = builtins.match "([a-z0-9-]+)[.]sammasak[.]dev" n;
        in
        if m == null then [ ] else m
      ) (lib.attrNames edge.services.caddy.virtualHosts)
    );
    secrets = lib.listToAttrs (
      map (c: lib.nameValuePair c.networking.hostName (lib.attrNames (c.sops.secrets or { }))) systems
    );
  };
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../lib/app-manifest
      ../modules/core/fleet.nix
      ../scripts/test-app-manifest.py
    ];
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        app-manifest =
          # an edge.nix domain other than facts.nix's leaves no names, and every edge collision would pass
          assert lib.assertMsg (hostFacts.edgeNames != [ ])
            "app-manifest-check: the edge serves no name under lib/app-manifest/facts.nix's domain; has edge.nix's moved?";
          pkgs.runCommand "app-manifest"
            {
              nativeBuildInputs = [
                pkgs.nix
                pkgs.python3
              ];
              hostFacts = builtins.toJSON hostFacts;
              passAsFile = [ "hostFacts" ];
            }
            ''
              export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_LOG_DIR=$TMPDIR/log NIX_CONF_DIR=$TMPDIR/etc
              python3 ${src}/scripts/test-app-manifest.py --store dummy:// --lib ${pkgs.path}/lib --host-facts "$hostFactsPath"
              touch $out
            '';
      };
    };
}
