# x86-only: `--all-systems` would try to build an aarch64 check, and the
# packages follow so the docs name one system.
{ config, inputs, lib, ... }:
{
  flake.modules.nixos.agent-runtime = ../modules/agent-runtime;
  flake.nixosModules.agent-runtime = config.flake.modules.nixos.agent-runtime;
  flake.lib.agentRuntime = { pkgs }: import ../modules/agent-runtime/lib.nix { inherit lib pkgs; };

  perSystem =
    { pkgs, system, ... }:
    let
      x86Only = lib.optionalAttrs (system == "x86_64-linux");
      runtime = config.flake.lib.agentRuntime { inherit pkgs; };
      args = { inherit (inputs) factum skills; };
      templates = import ../tests/agent-runtime/templates.nix args;
      manifests = (runtime.evalManifests { modules = [ templates ]; }).manifestDir;
      tools = import ../modules/agent-runtime/runtime.nix { inherit pkgs; };
      optionsDoc = pkgs.nixosOptionsDoc {
        inherit (runtime) options;
        # repo-relative declaration paths in the rendered reference
        transformOptions =
          opt:
          opt
          // {
            declarations = map (d: lib.removePrefix "${toString ../.}/" (toString d)) opt.declarations;
          };
      };
    in
    {
      checks = x86Only {
        agent-runtime-eval = import ../tests/agent-runtime/check.nix {
          inherit pkgs lib runtime templates manifests;
          cases = import ../tests/agent-runtime/cases.nix (args // { inherit lib; });
          factumRev = inputs.factum.rev;
        };
        agent-runtime-runtime = import ../tests/agent-runtime/runtime-check.nix { inherit pkgs lib manifests; };
      };
      packages = x86Only {
        agent-runtime-options = optionsDoc.optionsCommonMark;
        agent-runtime-manifests = manifests;
        agent-runtime-assign = tools.assign;
        agent-runtime-materialize = tools.materialize;
        agent-runtime-export = tools.export;
        agent-runtime-reclaim = tools.reclaim;
      };
    };
}
