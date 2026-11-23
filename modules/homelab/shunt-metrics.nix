# The Shunt collector (scripts/shunt-metrics.py): every 15 minutes it reads the owner's Claude Code hook log on this
# host, read-only and offline, and leaves the last 24 h of Shunt decisions for this host's node-exporter; on a host
# with dev environments a unit per declared instance does the same for its home, labelled worker. Every series
# carries shunt="on|off", the declared sam.claude.bulkReader.enable of the host or that guest, so the two compare.
# A static claude_auto_compact_window_info series per host and guest names its declared sam.claude.autoCompactWindow
# (variant, "default" when null), for joining the compaction comparison (#626).
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
  onOff = enable: if enable then "on" else "off";
  envs = config.services.devEnvironments or { instances = { }; };
  guests = lib.attrNames envs.instances;
  guestDir = "/var/lib/shunt-metrics-guests";
  guestUnit = n: "shunt-metrics-guest-${n}";
  variant = w: if w == null then "default" else toString w;
  compactionInfo = pkgs.writeText "claude-compaction.prom" (
    lib.concatLines (
      [
        "# HELP claude_auto_compact_window_info The declared Claude Code autoCompactWindow in tokens, or default."
        "# TYPE claude_auto_compact_window_info gauge"
        ''claude_auto_compact_window_info{variant="${variant config.sam.claude.autoCompactWindow}"} 1''
      ]
      ++ map (
        n:
        ''claude_auto_compact_window_info{worker="${n}",variant="${variant config.containers.${n}.config.sam.claude.autoCompactWindow}"} 1''
      ) guests
    )
  );
  timer = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:07/15";
      Persistent = true;
    };
  };
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  options.homelab.shuntMetrics.enable = lib.mkEnableOption "the Shunt collector over the owner's Claude Code hook log";

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.prometheus.exporters.node.extraFlags = [
          "--collector.textfile.directory=${dir}"
        ]
        ++ lib.optional (guests != [ ]) "--collector.textfile.directory=${guestDir}";
        # node-exporter counts a missing directory as a textfile scrape error until the first run creates it; a removed
        # instance's file ages out by its mtime
        systemd.tmpfiles.rules = [
          "d ${dir} 0755 ${user} - -"
          # its mtime is the store's epoch: no textfile freshness rule may match it
          "L+ ${dir}/claude-compaction.prom - - - - ${compactionInfo}"
        ]
        ++ lib.optional (guests != [ ]) "d ${guestDir} 0755 root root m:2d";

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
              "--shunt"
              (onOff config.sam.claude.bulkReader.enable)
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
      }
      {
        # The guest controls its home: the script opens no directory or day file through a link, and the worker
        # and shunt labels come from this host's declaration. One unit per guest, so a guest whose log stalls its
        # run stales its own series alone, and each passes its own guest's switch.
        systemd.services = lib.listToAttrs (
          map (
            n:
            lib.nameValuePair (guestUnit n) {
              description = "Shunt metrics from dev-environment guest ${n}'s Claude Code hook log, for node-exporter";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = lib.escapeShellArgs [
                  (lib.getExe pkgs.python3)
                  "-I"
                  "${../../scripts/shunt-metrics.py}"
                  "--out"
                  "${guestDir}/shunt-guest-${n}.prom"
                  "--shunt"
                  (onOff config.containers.${n}.config.sam.claude.bulkReader.enable)
                  "--state-dir"
                  envs.stateDir
                  "--worker"
                  n
                ];
                StateDirectory = "shunt-metrics-guests";
                StateDirectoryMode = "0755";
                TimeoutStartSec = 90;
                MemoryMax = "48M";
                Nice = 10;
                # root, not DynamicUser, as nav-metrics-guest@: node-exporter must read the dir; the 0700 instance
                # dirs and homes are read by CAP_DAC_READ_SEARCH alone
                CapabilityBoundingSet = "CAP_DAC_READ_SEARCH";
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                PrivateNetwork = true;
              };
            }
          ) guests
        );
        systemd.timers = {
          shunt-metrics = timer;
        }
        // lib.genAttrs (map guestUnit guests) (_: timer);

        assertions = [
          {
            assertion = config.sam.profile.devTools;
            message = "homelab.shuntMetrics: it reads the owner's Claude Code hook log, which only a devTools host has; enable it there alone.";
          }
        ];
      }
    ]
  );
}
