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
  # without lib.sh's prelude: its ERR trap would stop the preflight at the first failing check
  standalone =
    name: inputs:
    pkgs.writeShellApplication {
      name = "agent-runtime-${name}";
      runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux ] ++ inputs;
      text = builtins.readFile ./runtime/${name}.sh;
    };
  adapter = lib.genAttrs [ "assign" "materialize" "export" "reclaim" ] (name: tool name [ ]);
  # gnused: start parses systemd-run's invocation line and the veth peer with sed; without it a
  # lean-PATH caller (a Herdr pane) died after the unit had started (#161 review)
  instance = tool "instance" (
    lib.attrValues adapter
    ++ (with pkgs; [ bash gawk gnugrep gnused diffutils e2fsprogs procps systemd inetutils iproute2 nftables getent ])
  );
  # #170: the narrow privileged entry point. It derives the payload from the manifest, so the
  # instance store path is substituted in (not a PATH lookup); jq/coreutils, and logger for the
  # journal copy of each audit line, are its only inputs.
  authorizedStart = pkgs.writeShellApplication {
    name = "agent-runtime-authorized-start";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux ];
    text = builtins.replaceStrings [ "@instance@" ] [ "${lib.getExe instance}" ] (
      builtins.readFile ./runtime/authorized-start.sh
    );
  };
  # the pilot's host side (#165): read-only no-go checks, and the pane a runtime's handoff lands in
  preflight = standalone "preflight" [ instance pkgs.gawk pkgs.getent pkgs.herdr pkgs.systemd ];
in
adapter
// {
  inherit instance authorizedStart preflight;
  boot = standalone "boot" [ instance preflight ];
  pane = standalone "pane" [ instance ];
  # the trusted host's check of an exported bundle before review or promotion (#169); never runs the patch
  verify = tool "verify" [ pkgs.gawk ];
  # verify-gated promotion of a bundle onto a checkout (#169); records the commit sha, no fetch/push/token
  promote = tool "promote" [ (tool "verify" [ pkgs.gawk ]) ];
}
