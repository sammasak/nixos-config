# The navigation collector (scripts/nav-metrics.py, docs/shipping.md) on each devTools host: hourly it reads the
# owner's Claude Code transcripts on this host, read-only and offline, and leaves counts for this host's node-exporter.
# Transcripts inside dev-environment guests are not read.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dir = "/var/lib/nav-metrics";
  user = config.sam.profile.username;
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
  # node-exporter counts a missing directory as a textfile scrape error (NodeTextFileCollectorScrapeError) until the
  # first run creates it
  systemd.tmpfiles.rules = [ "d ${dir} 0755 ${user} - -" ];

  systemd.services.nav-metrics = {
    description = "Navigation metrics from the owner's Claude Code transcripts, for node-exporter";
    environment.HOME = "/home/${user}";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.python3)
        "-I"
        "${../../scripts/nav-metrics.py}"
        "--out"
        "${dir}/nav.prom"
      ];
      StateDirectory = "nav-metrics";
      StateDirectoryMode = "0755";
      # above the script's own 240 s deadline
      TimeoutStartSec = 300;
      # 24 MB peak, page cache included (the script drops it behind its reads), flat from lenovo's day to a 500 MB
      # synthetic one; counted in lenovo's sam.memory budget
      MemoryMax = "48M";
      Nice = 10;
      ProtectSystem = "strict";
      # an empty /home with the transcripts alone bound in, read-only; "-": a host without them yet still starts
      ProtectHome = "tmpfs";
      BindReadOnlyPaths = [ "-/home/${user}/.claude/projects" ];
      PrivateTmp = true;
      PrivateNetwork = true;
      NoNewPrivileges = true;
    };
  };
  systemd.timers.nav-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:23";
      Persistent = true;
    };
  };

  assertions = [
    {
      assertion = config.sam.profile.devTools;
      message = "modules/homelab/nav-metrics.nix: it reads the owner's agent transcripts, which only a devTools host has; import it there alone.";
    }
  ];
}
