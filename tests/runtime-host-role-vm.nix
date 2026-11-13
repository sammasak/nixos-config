# The runtime-host role (msi-ms7758, acer-swift) booted in QEMU, for what evaluation
# cannot show: every unit of the boot comes up, Home Manager's activation included,
# and a switch into a generation with a failing unit exits non-zero, which deploy-rs's
# autoRollback depends on. A host-sized closure: `just role-vm-test` on msi, never lenovo.
# `.broken` fails Home Manager's activation on purpose, so it must fail.
{ pkgs, roleModules, fleetModules }:
let
  vars = import ../hosts/msi-ms7758/variables.nix;

  test = pkgs.testers.runNixOSTest {
    name = "runtime-host-role";
    # The fleet's modules set nixpkgs.overlays, which read-only pkgs refuses.
    node.pkgsReadOnly = false;

    nodes.machine =
      { lib, ... }:
      {
        # msi's roles minus homelab-agent: no k3s, whose server is lenovo.
        imports = roleModules ++ fleetModules vars.hostname vars.username;
        sam.profile = vars // {
          # The relay needs msi's native_otlp_auth secret.
          nativeOtel = false;
        };
        # Stubs for state a VM lacks: the host key the secrets are encrypted to, and an NTP
        # server, without which systemd-time-wait-sync never finishes (nixos:runtime-host-test checks it is wanted).
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
      machine.wait_for_unit("home-manager-${vars.username}.service")
      machine.wait_for_open_port(22)
      failed = machine.succeed("systemctl list-units --failed --plain --no-legend").strip()
      assert failed == "", f"failed units after boot:\n{failed}"

      rc, out = machine.execute("/run/current-system/specialisation/failing-unit/bin/switch-to-configuration test 2>&1")
      print(out)
      assert rc != 0, "a switch that leaves a failed unit exited 0"
      assert "failing-on-purpose.service" in out, "the switch did not name the failed unit"
    '';
  };
in
test
// {
  broken = test.extendNixOS {
    module.home-manager.users.${vars.username} =
      { lib, ... }:
      {
        home.activation.brokenOnPurpose = lib.hm.dag.entryAfter [ "writeBoundary" ] "exit 1";
      };
  };
}
