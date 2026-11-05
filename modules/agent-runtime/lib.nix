# Standalone evaluation of agent-runtime templates (no nixosSystem): used by
# the eval tests and by consumers that only want manifests.
{ lib, pkgs }:
{
  evalManifests =
    { modules }:
    let
      eval = lib.evalModules {
        specialArgs = { inherit pkgs; };
        modules = [
          lib.genericModules.assertions
          ./default.nix
        ]
        ++ modules;
      };
      failed = map (a: a.message) (builtins.filter (a: !a.assertion) eval.config.assertions);
    in
    if failed == [ ] then
      eval.config.sam.agentRuntime
    else
      throw "agent-runtime: ${lib.concatStringsSep "\n" failed}";
}
