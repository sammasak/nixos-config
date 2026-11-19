# The real systemd post-start lifecycle, with synthetic backups and no production data or credentials.
{ lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.backup-metrics-systemd = pkgs.testers.runNixOSTest {
        name = "backup-metrics-systemd";
        nodes.machine = { pkgs, ... }: {
          imports = [ ../modules/homelab/backup-metrics.nix ];
          services.prometheus.exporters.node = {
            enable = true;
            extraFlags = [ "--collector.textfile.directory=/run/node-exporter-textfile" ];
          };
          systemd.tmpfiles.rules = [ "d /run/node-exporter-textfile 0755 root root -" ];
          users.groups.backup-fixture = { };
          users.users.backup-fixture = {
            isSystemUser = true;
            group = "backup-fixture";
          };
          homelab.backupMetrics.jobs.fixture-backup = "archive_list";
          systemd.services.fixture-backup = {
            unitConfig.ConditionPathExists = "/run/backup-fixture-ready";
            serviceConfig = {
              Type = "oneshot";
              User = "backup-fixture";
              Group = "backup-fixture";
              ProtectSystem = "strict";
              PrivateNetwork = true;
            };
            script = ''
              if test -e /run/backup-fixture-fail; then exit 1; fi
              ${pkgs.coreutils}/bin/sleep 1
            '';
          };
        };
        testScript = ''
          import json
          start_all()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("systemctl stop backup-metrics.timer")
          machine.succeed("systemctl start backup-metrics.service")
          machine.succeed("grep 'backup=\"fixture-backup\",validation=\"archive_list\"} 0' /run/node-exporter-textfile/backup.prom")
          machine.fail("grep '^homelab_backup_last_success_timestamp_seconds{' /run/node-exporter-textfile/backup.prom")

          machine.succeed("touch /run/backup-fixture-ready; systemctl start fixture-backup.service")
          path = "/var/lib/backup-metrics/fixture-backup/success.json"
          before = machine.succeed("cat " + path)
          success = json.loads(before)
          assert success["unit"] == "fixture-backup"
          assert success["duration_seconds"] >= 1
          assert abs(float(machine.succeed("date +%s")) - success["completed_at"]) < 30
          assert machine.succeed("stat -c %a " + path).strip() == "600"
          assert machine.succeed("stat -c %U /var/lib/backup-metrics/fixture-backup").strip() == "backup-fixture"
          machine.fail("su -s /bin/sh nobody -c 'cat " + path + "'")
          machine.succeed("systemctl start backup-metrics.service")
          machine.succeed("grep '^homelab_backup_last_success_timestamp_seconds{' /run/node-exporter-textfile/backup.prom")
          machine.succeed("su -s /bin/sh nobody -c 'cat /run/node-exporter-textfile/backup.prom'")

          machine.succeed("touch /run/backup-fixture-fail")
          machine.fail("systemctl start fixture-backup.service")
          assert machine.succeed("cat " + path) == before
          machine.succeed("systemctl reset-failed fixture-backup.service; rm /run/backup-fixture-ready")
          machine.succeed("systemctl start fixture-backup.service")
          assert machine.succeed("cat " + path) == before

          # A broken metric destination must not make a valid synthetic backup fail.
          machine.succeed("rm /run/backup-fixture-fail; touch /run/backup-fixture-ready; rm " + path + "; mkdir " + path)
          machine.succeed("systemctl start fixture-backup.service")
          assert machine.succeed("systemctl show fixture-backup.service -p Result --value").strip() == "success"
          machine.succeed("systemctl start backup-metrics.service")
          machine.succeed("grep 'backup=\"fixture-backup\",validation=\"archive_list\"} 0' /run/node-exporter-textfile/backup.prom")
          machine.fail("grep '^homelab_backup_last_success_timestamp_seconds{' /run/node-exporter-textfile/backup.prom")
        '';
      };
    };
}
