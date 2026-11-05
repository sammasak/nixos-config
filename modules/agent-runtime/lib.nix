# Standalone evaluation of agent-runtime templates (no nixosSystem): the
# manifests throw the failed checks themselves (see `guarded` in default.nix).
{ lib, pkgs }:
let
  eval =
    modules:
    lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [
        lib.genericModules.assertions
        ./default.nix
      ]
      ++ modules;
    };
in
{
  evalManifests = { modules }: (eval modules).config.sam.agentRuntime;
  options = (eval [ ]).options.sam;
}
