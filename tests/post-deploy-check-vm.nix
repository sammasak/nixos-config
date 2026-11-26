# scripts/post-deploy-check.sh (just deploy's post-deploy check) against real systemd states, run as an unprivileged
# user the way deploy runs it: a failed unit, one waiting to restart and one activating again after a restart each fail
# it, a condition-skipped unit and a plain long-running oneshot do not. `nix build .#checks.x86_64-linux.post-deploy-check-vm`.
{ pkgs }:
let
  check = ../scripts/post-deploy-check.sh;
  sh = script: "${pkgs.bash}/bin/bash -c ${pkgs.lib.escapeShellArg script}";
in
pkgs.testers.runNixOSTest {
  name = "post-deploy-check";

  nodes.machine = {
    users.users.checker = {
      isSystemUser = true;
      group = "checker";
    };
    users.groups.checker = { };

    systemd.services = {
      skipped = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.ConditionPathExists = "/nonexistent";
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
      };
      broken.serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/false";
      };
      # the ExecStart=false loop, held between restarts so the check sees it there
      waiting.serviceConfig = {
        ExecStart = "${pkgs.coreutils}/bin/false";
        Restart = "always";
        RestartSec = "1h";
      };
      # fails once, then hangs in its restarted start: activating with NRestarts=1
      restarted.serviceConfig = {
        Type = "oneshot";
        ExecStart = sh "[ -e /run/restarted-once ] && exec sleep infinity; touch /run/restarted-once; exit 1";
        Restart = "on-failure";
        RestartSec = "1s";
      };
      # a oneshot still running at the check, as a timer's job may be: activating, never restarted
      slow.serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };
  };

  testScript = ''
    def run_check():
        return machine.execute("runuser -u checker -- bash -s < ${check} 2>&1")

    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl start --no-block slow.service")
    machine.wait_until_succeeds("systemctl show -p ActiveState --value slow.service | grep -qx activating")

    with subtest("a healthy host passes; a condition-skipped unit is listed, not failed"):
        rc, out = run_check()
        print(out)
        assert rc == 0, f"rc {rc}"
        skips = [line for line in out.splitlines() if "condition skipped (not a failure):" in line]
        assert len(skips) == 1 and " skipped.service" in skips[0], out
        assert "slow.service" not in out, out

    with subtest("an ExecStart=false unit waiting to restart fails it"):
        machine.succeed("systemctl start waiting.service")
        machine.wait_until_succeeds("systemctl show -p SubState --value waiting.service | grep -qx auto-restart")
        rc, out = run_check()
        print(out)
        assert rc == 1 and "restart loop: waiting.service (activating/auto-restart" in out, out
        machine.succeed("systemctl stop waiting.service")

    with subtest("a unit activating again after a restart fails it"):
        machine.succeed("systemctl start --no-block restarted.service")
        machine.wait_until_succeeds("systemctl show -p NRestarts --value restarted.service | grep -qx 1")
        machine.wait_until_succeeds("systemctl show -p SubState --value restarted.service | grep -qx start")
        rc, out = run_check()
        print(out)
        assert rc == 1 and "restart loop: restarted.service (activating/start, 1 restarts)" in out, out
        machine.succeed("systemctl stop restarted.service; systemctl reset-failed restarted.service")

    with subtest("a failed unit degrades the system and fails it"):
        machine.fail("systemctl start broken.service")
        rc, out = run_check()
        print(out)
        assert rc == 1 and "system is degraded" in out and "failed unit: broken.service" in out, out
        assert "restarted.service" not in out, out
        machine.succeed("systemctl reset-failed")

    with subtest("passes again once nothing is failed or looping"):
        rc, out = run_check()
        assert rc == 0, out
  '';
}
