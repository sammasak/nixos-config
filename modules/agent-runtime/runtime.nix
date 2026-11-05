# The runtime adapter (#136) and the instance lifecycle over it (#138), sharing
# one error prelude. `nix` is a parameter so the check can answer `flake
# prefetch` and `build --out-link` without network.
{ lib, pkgs, nix ? pkgs.nix }:
let
  tool =
    name: inputs:
    pkgs.writeShellApplication {
      name = "agent-runtime-${name}";
      runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.git pkgs.jq pkgs.util-linux nix ] ++ inputs;
      text = builtins.readFile ./runtime/lib.sh + builtins.readFile ./runtime/${name}.sh;
    };
  adapter = lib.genAttrs [ "assign" "materialize" "export" "reclaim" ] (name: tool name [ ]);
in
adapter
// {
  instance = tool "instance" (
    lib.attrValues adapter
    ++ (with pkgs; [ bash gawk gnugrep diffutils e2fsprogs procps systemd inetutils iproute2 nftables glibc.bin ])
  );
}
