# One registry admitted against the fleet, lib-only: what scripts/test-app-manifest.py evaluates per fixture.
{
  nixpkgsLib,
  hostFacts,
  registry,
  # "refusals": the refused rules' messages as a list, for the fixtures' exact comparison; "render": the admitted
  # apps' Caddyfile and Prometheus config, for the golden files
  what ? "admit",
}:
let
  lib = import nixpkgsLib;
  manifest = import ./. { inherit lib; };
  fleet = (lib.evalModules { modules = [ ../../modules/core/fleet.nix ]; }).config.sam.fleet;
  facts = manifest.facts ({ inherit fleet; } // lib.importJSON hostFacts);
  # a static app's package as the platform would build it: a fixed stand-in, so the golden files never move
  package = n: "/nix/store/${lib.strings.replicate 32 "0"}-${n}";
  render =
    let
      r = manifest.render facts registry package;
    in
    {
      inherit (r) caddyfile;
      prometheus.scrape_configs = r.scrapeConfigs;
    };
in
if what == "render" then render else manifest.${what} facts registry
