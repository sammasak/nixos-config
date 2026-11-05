# Standalone entry points (no nixosSystem): template evaluation, whose manifests
# throw the failed checks themselves (see `guarded` in default.nix), and the
# runtime adapter tools.
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
  tools = import ./runtime.nix { inherit lib pkgs; };
  options = (eval [ ]).options.sam;
}
