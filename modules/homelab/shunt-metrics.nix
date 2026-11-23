# The Shunt collector (scripts/shunt-metrics.py): every 15 minutes it reads the owner's Claude Code hook log on this
# host, read-only and offline, and leaves the last 24 h of Shunt decisions for this host's node-exporter. Only that
# one log is read: sessions in dev-environment guests log in their own homes and are not counted.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.shuntMetrics;
  dir = "/var/lib/shunt-metrics";
  user = config.sam.profile.username;
  logDir = "/home/${user}/.local/state/claude-hooks";
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  options.homelab.shuntMetrics.enable = lib.mkEnableOption "the Shunt collector over the owner's Claude Code hook log";

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
    # node-exporter counts a missing directory as a textfile scrape error until the first run creates it
    systemd.tmpfiles.rules = [ "d ${dir} 0755 ${user} - -" ];

    systemd.services.shunt-metrics = {
      description = "Shunt metrics from the owner's Claude Code hook log, for node-exporter";
      environment.HOME = "/home/${user}";
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.python3)
          "-I"
          "${../../scripts/shunt-metrics.py}"
          "--out"
          "${dir}/shunt.prom"
          "--log-dir"
          logDir
        ];
        StateDirectory = "shunt-metrics";
        StateDirectoryMode = "0755";
        # above the script's own 60 s deadline
        TimeoutStartSec = 90;
        # peaks: 23 MB on a 500-record day, 25 MB on a 64 MiB day file past the script's 200,000-record cap
        MemoryMax = "48M";
        Nice = 10;
        ProtectSystem = "strict";
        # an empty /home with the hook log alone bound in, read-only; "-": a host without it yet still starts
        ProtectHome = "tmpfs";
        BindReadOnlyPaths = [ "-${logDir}" ];
        PrivateTmp = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
      };
    };
    systemd.timers.shunt-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:07/15";
        Persistent = true;
      };
    };

    assertions = [
      {
        assertion = config.sam.profile.devTools;
        message = "homelab.shuntMetrics: it reads the owner's Claude Code hook log, which only a devTools host has; enable it there alone.";
      }
    ];
  };
}
