# The runtime adapter (#136): four executables over the manifests. `nix` is a
# parameter so the check can answer `flake prefetch` without network.
{ pkgs, nix ? pkgs.nix }:
let
  tool =
    name:
    pkgs.writeShellApplication {
      name = "agent-runtime-${name}";
      runtimeInputs = [ pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.jq nix ];
      text = builtins.readFile ./runtime/${name}.sh;
    };
in
{
  assign = tool "assign";
  materialize = tool "materialize";
  export = tool "export";
  reclaim = tool "reclaim";
}
