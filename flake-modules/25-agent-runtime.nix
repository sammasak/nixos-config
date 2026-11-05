# Public agent-runtime module (registry entry published as nixosModules; this
# flake strips `modules` from its outputs), its evaluator, the eval check and
# the option reference. Checks stay x86-only: `--all-systems` would try to
# build an aarch64 derivation here.
{ config, inputs, lib, ... }:
{
  flake.modules.nixos.agent-runtime = ../modules/agent-runtime;
  flake.nixosModules.agent-runtime = config.flake.modules.nixos.agent-runtime;
  flake.lib.agentRuntime = { pkgs }: import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };

  perSystem =
    { pkgs, system, ... }:
    let
      runtime = config.flake.lib.agentRuntime { inherit pkgs; };
      args = { inherit (inputs) factum skills; };
      templates = import ../tests/agent-runtime/templates.nix args;
      manifests = (runtime.evalManifests { modules = [ templates ]; }).manifestDir;
      optionsDoc = pkgs.nixosOptionsDoc {
        options =
          (lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              lib.genericModules.assertions
              ../modules/agent-runtime
            ];
          }).options.sam;
        transformOptions =
          opt: opt // { declarations = map (d: lib.removePrefix "${toString ../.}/" (toString d)) opt.declarations; };
      };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-eval = import ../tests/agent-runtime/check.nix {
          inherit pkgs lib runtime templates manifests;
          cases = import ../tests/agent-runtime/cases.nix (args // { inherit lib; });
          factumRev = inputs.factum.rev;
        };
      };
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-options = optionsDoc.optionsCommonMark;
        agent-runtime-manifests = manifests;
      };
    };
}
