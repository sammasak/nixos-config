# The runtime-host role (msi-ms7758, acer-swift) booted in QEMU, for what evaluation
# cannot show: every system unit of the boot comes up, Home Manager's activation
# included, and a switch into a generation with a failing unit exits 4 and fails
# nothing else. System manager only: a failed Home Manager user unit (herdr) is not
# seen. Not in the VM: hosts/msi-ms7758/configuration.nix (GRUB, WoL, power schedule).
# A host-sized closure: `just role-vm-test` on msi only.
# `.broken` fails Home Manager's activation on purpose; it means something only next to a passing plain run.
{
  pkgs,
  roleModules,
  fleetModules,
  roles,
}:
let
  test = pkgs.testers.runNixOSTest {
    name = "runtime-host-role";
    # The fleet's modules set nixpkgs.overlays, which read-only pkgs refuses.
    node.pkgsReadOnly = false;

    nodes.machine =
      { lib, ... }:
      {
        # msi's roles minus homelab-agent: no k3s, whose server is lenovo.
        imports = roleModules ++ fleetModules;
        sam.profile = {
          username = "lukas";
          hostname = "msi-ms7758";
          inherit roles;
          # The relay needs msi's native_otlp_auth secret.
          nativeOtel = false;
        };
        # As msi sets it in its host file, which the VM does not import; no unit, kept so the closure matches msi.
        sam.cliTools.nixAudit.enable = true;
        # Stubs for state a VM lacks: the host key the secrets are encrypted to, and an NTP
        # server, without which systemd-time-wait-sync never finishes.
        sam.hostSecrets.enable = lib.mkForce false;
        systemd.services.systemd-time-wait-sync.wantedBy = lib.mkForce [ ];
        virtualisation.memorySize = 2048;

        specialisation.failing-unit.configuration.systemd.services.failing-on-purpose = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = "exit 1";
        };
      };

    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("home-manager-lukas.service")
      machine.wait_for_open_port(22)
      failed = machine.succeed("systemctl list-units --failed --plain --no-legend").strip()
      assert failed == "", f"failed units after boot:\n{failed}"

      rc, out = machine.execute("/run/current-system/specialisation/failing-unit/bin/switch-to-configuration test 2>&1")
      print(out)
      assert rc == 4, f"a switch that leaves a failed unit exited {rc}, not 4"
      failed = machine.succeed("systemctl list-units --failed --plain --no-legend | cut -d' ' -f1").split()
      assert failed == ["failing-on-purpose.service"], f"failed units after the switch: {failed}"
    '';
  };
in
test
// {
  broken = test.extendNixOS {
    module.home-manager.users.lukas =
      { lib, ... }:
      {
        home.activation.brokenOnPurpose = lib.hm.dag.entryAfter [ "writeBoundary" ] "exit 1";
      };
  };
}
