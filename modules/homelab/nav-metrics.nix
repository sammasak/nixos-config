# The navigation collector (scripts/nav-metrics.py, docs/shipping.md) on each devTools host: hourly it reads the
# owner's Claude Code transcripts on this host, read-only and offline, and leaves counts for this host's node-exporter;
# on a host with dev environments a unit per declared instance does the same for its home, labelled worker.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dir = "/var/lib/nav-metrics";
  user = config.sam.profile.username;
  # a host without modules/workers has no such option
  envs = config.services.devEnvironments or { };
  guests = lib.attrNames (envs.instances or { });
  guestDir = "/var/lib/nav-metrics-guests";
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  services.prometheus.exporters.node.extraFlags = [
    "--collector.textfile.directory=${dir}"
  ]
  ++ lib.optional (guests != [ ]) "--collector.textfile.directory=${guestDir}";
  # node-exporter counts a missing directory as a textfile scrape error (NodeTextFileCollectorScrapeError) until the
  # first run creates it. A removed instance's file ages out by its mtime: node-exporter's reads keep its atime fresh.
  systemd.tmpfiles.rules = [
    "d ${dir} 0755 ${user} - -"
  ]
  ++ lib.optional (guests != [ ]) "d ${guestDir} 0755 root root m:2d";

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
  # The guest controls its home: the script opens nothing through a link and nothing but a regular file, and the
  # worker label is the declared name. One process, file and MemoryMax per guest: a guest whose transcripts kill or
  # stall its run stales its own series alone.
  systemd.services."nav-metrics-guest@" = lib.mkIf (guests != [ ]) {
    description = "Navigation metrics from dev-environment guest %i's Claude Code transcripts, for node-exporter";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.python3)
        "-I"
        "${../../scripts/nav-metrics.py}"
        "--out"
        "${guestDir}/nav-guest-%i.prom"
        "--state-dir"
        envs.stateDir
        "--home"
        envs.paths.home
        "--worker"
        "%i"
      ];
      StateDirectory = "nav-metrics-guests";
      StateDirectoryMode = "0755";
      TimeoutStartSec = 300;
      # 27 MB peak on a real 226 MB day, 50 MB with every per-session state at the script's caps plus lines just
      # under its LINE_MAX
      MemoryMax = "64M";
      Nice = 10;
      # root, not DynamicUser: a dynamic user's StateDirectory sits under the 0700 /var/lib/private, which node-exporter
      # cannot read. It reads the 0700 instance dirs and homes by CAP_DAC_READ_SEARCH alone and writes only its own dir.
      CapabilityBoundingSet = "CAP_DAC_READ_SEARCH";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      # a device node a guest root made opens EPERM before any driver code runs
      PrivateDevices = true;
      PrivateNetwork = true;
    };
  };
  systemd.timers = {
    nav-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:23";
        Persistent = true;
      };
    };
  }
  // lib.genAttrs (map (n: "nav-metrics-guest@${n}") guests) (_: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:38";
      Persistent = true;
    };
  });

  assertions = [
    {
      assertion = config.sam.profile.devTools;
      message = "modules/homelab/nav-metrics.nix: it reads the owner's agent transcripts, which only a devTools host has; import it there alone.";
    }
  ];
}
