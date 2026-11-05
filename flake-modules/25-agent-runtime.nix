# Public agent-runtime module, its standalone evaluator, the eval check and
# the option reference. Checks stay x86-only: `--all-systems` would try to
# build an aarch64 derivation here.
{ inputs, lib, ... }:
{
  flake.modules.nixos.agent-runtime = ../modules/agent-runtime;
  flake.nixosModules.agent-runtime = ../modules/agent-runtime;
  flake.lib.agentRuntime = { pkgs }: import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };

  perSystem =
    { pkgs, system, ... }:
    let
      optionsDoc = pkgs.nixosOptionsDoc {
        options =
          (lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              lib.genericModules.assertions
              ../modules/agent-runtime
            ];
          }).options.sam;
      };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-eval = import ../tests/agent-runtime/check.nix { inherit pkgs lib inputs; };
      };
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-options = optionsDoc.optionsCommonMark;
        agent-runtime-manifests =
          ((import ../modules/agent-runtime/lib.nix { inherit lib pkgs; }).evalManifests {
            modules = [ (import ../tests/agent-runtime/templates.nix { inherit (inputs) factum skills; }) ];
          }).manifestDir;
      };
    };
}
