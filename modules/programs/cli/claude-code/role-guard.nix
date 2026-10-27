# The role guard library from the skills input, built into the store (skills epic #16): the dispatcher hook
# prefers this binary over the checkout's own devenv task, so a checkout the agent can write cannot change
# its guard code. Imported applied:  (import ./role-guard.nix skillsSrc) pkgs
skillsSrc: pkgs:
let
  lib = pkgs.lib;
in
rec {
  shipped = builtins.pathExists "${skillsSrc}/task-modules/guard-lib.nix";
  bin = pkgs.writeShellApplication {
    name = "guard-check";
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    text = import "${skillsSrc}/task-modules/guard-lib.nix" + "\nguard_main\n";
  };
  dispatcher = "${skillsSrc}/hooks/role-guard-dispatch.sh";
  # env prefix for a hook command: empty when the pinned skills do not ship the library yet
  envPrefix = lib.optionalString shipped "ROLE_GUARD_BIN=${bin}/bin/guard-check ";
}
