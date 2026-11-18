# One registry admitted against the fleet, lib-only: what scripts/test-app-manifest.py evaluates per fixture.
{
  nixpkgsLib,
  hostFacts,
  registry,
  # "refusals": the refused rules' messages as a list, for the fixtures' exact comparison
  what ? "admit",
}:
let
  lib = import nixpkgsLib;
  manifest = import ./. { inherit lib; };
  fleet = (lib.evalModules { modules = [ ../../modules/core/fleet.nix ]; }).config.sam.fleet;
  facts = manifest.facts ({ inherit fleet; } // lib.importJSON hostFacts);
in
manifest.${what} facts registry
