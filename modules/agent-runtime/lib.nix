# Standalone entry points (no nixosSystem): template evaluation, whose manifests
# throw the failed checks themselves (see `guarded` in default.nix), and the
# runtime adapter tools, and the template profile a host receives with deploy-rs.
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
  # one host's deploy-rs agent-runtime profile: `agentRuntime` is its evaluated `sam.agentRuntime`
  templateProfile =
    { agentRuntime, substrateSchema ? 1 }:
    import ./template-profile.nix { inherit lib pkgs agentRuntime substrateSchema; };
  options = (eval [ ]).options.sam;
}
