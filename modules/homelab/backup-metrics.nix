# Post-success metadata only: backup identities write their own private state; the root collector exposes timestamps.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.backupMetrics;
  root = "/var/lib/backup-metrics";
  helper = pkgs.writeShellApplication {
    name = "backup-metrics";
    runtimeInputs = [
      pkgs.python3
      pkgs.systemd
    ];
    text = ''exec python3 -I ${../../scripts/backup-metrics.py} "$@"'';
  };
  jobs = pkgs.writeText "backup-metrics-jobs.json" (builtins.toJSON cfg.jobs);
in
{
  options.homelab.backupMetrics.jobs = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.enum [
        "archive_list"
        "scratch_restore"
      ]
    );
    default = { };
    description = "Existing backup unit names and validation performed by their main process.";
  };
  config = lib.mkIf (cfg.jobs != { }) {
    systemd.services =
      lib.mapAttrs (unit: _: {
        serviceConfig = {
          StateDirectory = lib.mkAfter [ "backup-metrics/${unit}" ];
          StateDirectoryMode = lib.mkDefault "0700";
          # A failed metric write must not turn a successfully completed backup into a failed backup.
          ExecStartPost = lib.mkAfter [
            "-${pkgs.coreutils}/bin/timeout --kill-after=2s 10s ${lib.getExe helper} record ${unit} ${root}/${unit}"
          ];
        };
      }) cfg.jobs
      // {
        backup-metrics = {
          description = "Expose successful backup completion metadata";
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe helper} collect ${jobs}";
            User = "root";
            ProtectSystem = "strict";
            ReadWritePaths = [ "/run/node-exporter-textfile" ];
            ProtectHome = true;
            PrivateTmp = true;
            PrivateNetwork = true;
            NoNewPrivileges = true;
            MemoryMax = "64M";
            TimeoutStartSec = 30;
          };
        };
      };
    systemd.timers.backup-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
      };
    };
    assertions = [
      {
        assertion = config.services.prometheus.exporters.node.enable;
        message = "backup-metrics requires the existing node-exporter textfile collector.";
      }
      {
        assertion = lib.all (unit: builtins.match "[a-z][a-z0-9-]*" unit != null) (lib.attrNames cfg.jobs);
        message = "backup-metrics job names must be simple system service names without .service.";
      }
    ];
  };
}
