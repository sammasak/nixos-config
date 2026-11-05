# The runtime adapter (#136): four executables over the manifests, sharing one
# error prelude. `nix` is a parameter so the check can answer `flake prefetch`
# and `build --out-link` without network.
{ lib, pkgs, nix ? pkgs.nix }:
lib.genAttrs [ "assign" "materialize" "export" "reclaim" ] (
  name:
  pkgs.writeShellApplication {
    name = "agent-runtime-${name}";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.git pkgs.jq pkgs.util-linux nix ];
    text = builtins.readFile ./runtime/lib.sh + builtins.readFile ./runtime/${name}.sh;
  }
)
