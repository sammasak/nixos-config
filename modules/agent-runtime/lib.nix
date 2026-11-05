# Standalone evaluation of agent-runtime templates (no nixosSystem): the
# manifests throw the failed checks themselves (see `guarded` in default.nix).
{ lib, pkgs }:
{
  evalManifests =
    { modules }:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        lib.genericModules.assertions
        ./default.nix
      ]
      ++ modules;
    }).config.sam.agentRuntime;
}
