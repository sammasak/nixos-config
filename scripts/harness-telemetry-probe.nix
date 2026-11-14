# The Claude settings scripts/test-harness-telemetry.py asserts on, from a flake's hosts: gate-probe.nix reads it with
# the pinned skills input, the test again with an overridden one (`nix eval --apply`).
hosts:
let
  settingsOf = c: { inherit (c.home-manager.users.lukas.programs.claude-code.settings) hooks env; };
in
{
  on = settingsOf hosts.lenovo.config;
  off =
    settingsOf
      (hosts.lenovo.extendModules {
        modules = [ ({ lib, ... }: { sam.claude.telemetry.enable = lib.mkForce false; }) ];
      }).config;
}
