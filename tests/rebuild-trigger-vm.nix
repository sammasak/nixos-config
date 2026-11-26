# The rebuild trigger's directory and path unit without a provisioning oneshot, in QEMU: a boot with the module reaches
# `running` with no ordering cycle, and a switch that turns the module on creates the directory from the tmpfiles rule
# alone. `nix build .#checks.x86_64-linux.rebuild-trigger-vm`.
{ pkgs }:
let
  base =
    { lib, ... }:
    {
      imports = [ ../modules/homelab/nixos-rebuild-trigger ];
      # the module reads the trigger user's name from the host profile
      options.sam.profile.username = lib.mkOption { default = "lukas"; };
      config.users.users.lukas = {
        isNormalUser = true;
        group = "users";
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "rebuild-trigger";

  nodes.booted = {
    imports = [ base ];
    homelab.nixosRebuildTrigger.enable = true;
  };
  nodes.switched = {
    imports = [ base ];
    specialisation.on.configuration.homelab.nixosRebuildTrigger.enable = true;
  };

  testScript = ''
    start_all()

    with subtest("a boot with the module is clean: running, no ordering cycle, directory and path unit up"):
        booted.wait_for_unit("multi-user.target")
        state = booted.succeed("systemctl is-system-running --wait || true").strip()
        assert state == "running", f"system state {state}: {booted.succeed('systemctl --failed --no-legend')}"
        booted.fail("journalctl -b | grep -i 'ordering cycle'")
        booted.succeed("test \"$(stat -c '%a %U %G' /run/nixos-rebuild-trigger)\" = '770 root users'")
        booted.succeed("systemctl is-active nixos-rebuild-trigger.path")

    with subtest("a switch that turns the module on creates the directory from tmpfiles alone"):
        switched.wait_for_unit("multi-user.target")
        switched.fail("test -e /run/nixos-rebuild-trigger")
        switched.succeed("/run/booted-system/specialisation/on/bin/switch-to-configuration test >&2")
        switched.succeed("test \"$(stat -c '%a %U %G' /run/nixos-rebuild-trigger)\" = '770 root users'")
        switched.succeed("systemctl is-active nixos-rebuild-trigger.path")
  '';
}
