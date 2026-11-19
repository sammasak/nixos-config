# App manifest admission and rendering (lib/app-manifest) over its fixtures, against the facts only host evaluations
# give: the names the edge serves, the snippets it defines and each host's sops secret names; sam.fleet itself it reads
# lib-only. The rendered sites are validated by caddy beside the edge's own snippet text, the scrape by promtool. No
# host imports lib/app-manifest, so no toplevel depends on it, and its source here is those files alone.
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
    # the `(name) {` snippet definitions a site may import
    forwardAuth = lib.concatMap (
      l:
      let
        m = builtins.match "[(]([a-z0-9-]+)[)] [{]" (lib.trim l);
      in
      if m == null then [ ] else m
    ) (lib.splitString "\n" edge.services.caddy.extraConfig);
    secrets = lib.listToAttrs (
      map (
        c:
        lib.nameValuePair c.networking.hostName (
          lib.attrNames (
            c.sops.secrets
              or (throw "app-manifest-check: ${c.networking.hostName} has no sops.secrets (sops-nix, in every host's fleetModules)")
          )
        )
      ) systems
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
              edgeSnippets = edge.services.caddy.extraConfig;
              passAsFile = [
                "hostFacts"
                "edgeSnippets"
              ];
            }
            ''
              export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_LOG_DIR=$TMPDIR/log NIX_CONF_DIR=$TMPDIR/etc
              python3 ${src}/scripts/test-app-manifest.py --store dummy:// --lib ${pkgs.path}/lib --host-facts "$hostFactsPath" \
                --caddy ${lib.getExe pkgs.caddy} --promtool ${pkgs.prometheus.cli}/bin/promtool --edge-snippets "$edgeSnippetsPath"
              touch $out
            '';
      };
    };
}
