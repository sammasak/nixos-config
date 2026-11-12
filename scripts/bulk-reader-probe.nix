# The Claude settings scripts/test-bulk-reader-hooks.py asserts on, from a flake's hosts: gate-probe.nix reads it with
# the pinned skills input, the test again with an overridden one (`nix eval --apply`).
hosts:
let
  settingsOf = c: { inherit (c.home-manager.users.lukas.programs.claude-code.settings) hooks env; };
  extend = host: modules: (hosts.${host}.extendModules { inherit modules; }).config;
  acer = extend "acer-swift" [ ({ lib, ... }: {
    sam.workers.instances = lib.mkForce { probe = { }; other = { }; };
    services.devEnvironments.guestModules = [ ({ devEnvironment, ... }: { sam.claude.bulkReader.enable = devEnvironment.name == "probe"; }) ];
  }) ];
in
{
  off = settingsOf hosts.lenovo.config;
  on = settingsOf (extend "lenovo" [ { sam.claude.bulkReader = { enable = true; minLines = 400; model = "sonnet"; }; } ]);
  guestOn = settingsOf acer.containers.probe.config;
  guestOff = settingsOf acer.containers.other.config;
}
