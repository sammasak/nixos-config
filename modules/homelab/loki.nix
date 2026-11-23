# Loki as a host service through upstream services.loki: single binary, filesystem, tsdb v13, 72h with 30 days
# for the two agent telemetry streams. Data under /var/lib/loki (chunks, rules, compactor, the rest under path_prefix).
# Upstream runs `loki -verify-config` on the rendered file at build time (only while extraFlags is empty); the
# flake check loki-config-msi-ms7758 (flake-modules/loki-check.nix) runs it on a seeded msi.
# - A crash loop slower than 3 starts per 1200 s never reaches failed, so it pages only once an absence alert exists.
# - After a start-limit hit the unit stays failed; recover with `systemctl reset-failed loki` and a start.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.loki;
  dataDir = config.services.loki.dataDir;
  retentionHours =
    let
      u = lib.substring (lib.stringLength cfg.retention - 1) 1 cfg.retention;
    in
    lib.toInt (lib.removeSuffix u cfg.retention)
    * {
      h = 1;
      d = 24;
      w = 168;
    }
    .${u};
  probeHost = if cfg.listenAddress == "0.0.0.0" then "127.0.0.1" else cfg.listenAddress;
  probeBudget = 180;
  unit = config.systemd.services.loki;
  # the firewall admits sam.fleet.loki's callers here (modules/core/network.nix)
  served = config.sam.fleet.loki.host == config.networking.hostName;
  inherit (config.sam.fleet) listeners;
in
{
  options.homelab.loki = {
    enable = lib.mkEnableOption "Grafana Loki as a host service";
    listenAddress = lib.mkOption {
      type = lib.types.strMatching "[0-9]+(\\.[0-9]+){3}";
      default = "127.0.0.1";
      description = ''
        IPv4 address of the HTTP API (push and query). gRPC stays on loopback. Any other address is reachable through
        the firewall's trusted interfaces (tailscale0 where it runs) whatever sam.fleet.loki.from says.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = config.sam.fleet.loki.port;
      defaultText = lib.literalExpression "config.sam.fleet.loki.port";
      description = "Loki's HTTP listen port, opened to sam.fleet.loki.from only and probed for /ready at start.";
    };
    retention = lib.mkOption {
      type = lib.types.strMatching "[0-9]+[hdw]";
      default = "72h";
      description = "Default retention, at least 24h (the index period); the two agent telemetry streams and the platform records keep 720h regardless.";
    };
    ntfyUrl = lib.mkOption {
      type = lib.types.strMatching "https?://.+";
      default = config.sam.fleet.pageUrl;
      defaultText = lib.literalExpression "config.sam.fleet.pageUrl";
      description = "ntfy topic URL paged when Loki fails.";
    };
    ruler.enable = lib.mkEnableOption ''
      Loki's ruler on the rules in modules/homelab/monitoring/loki-rules: alerts to sam.fleet.listeners.alertmanager,
      recordings by remote write to sam.fleet.listeners.prometheus, both served on this host
    '';
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # the collectors, pi-offload and alloy-otlp push to sam.fleet.loki.url
        assertion = cfg.port == config.sam.fleet.loki.port;
        message = "homelab.loki.port ${toString cfg.port} is not sam.fleet.loki.port ${toString config.sam.fleet.loki.port}: every pusher would miss Loki.";
      }
      {
        assertion = served -> !lib.hasPrefix "127." cfg.listenAddress;
        message = "homelab.loki: sam.fleet.loki is served here, but listenAddress ${cfg.listenAddress} is loopback, so nothing the firewall admits can reach Loki.";
      }
      {
        assertion = retentionHours >= 24;
        message = "homelab.loki.retention ${cfg.retention} is under 24h, Loki's minimum retention.";
      }
      {
        assertion = !lib.hasPrefix "127." cfg.listenAddress -> config.networking.firewall.enable;
        message = "homelab.loki.listenAddress ${cfg.listenAddress} without networking.firewall.enable exposes an unauthenticated Loki to every network.";
      }
      {
        assertion = probeBudget < unit.serviceConfig.TimeoutStartSec;
        message = "homelab.loki: the readiness probe's ${toString probeBudget} s must end before TimeoutStartSec, so a slow start fails its probe instead of being killed.";
      }
      {
        assertion =
          unit.startLimitBurst
          * (
            unit.serviceConfig.TimeoutStartSec
            + unit.serviceConfig.RestartSec
            + unit.serviceConfig.TimeoutStopSec
          ) <= unit.startLimitIntervalSec;
        message = "homelab.loki: startLimitBurst starts of TimeoutStartSec + RestartSec + TimeoutStopSec each must fit in startLimitIntervalSec, or a start loop never fails the unit and never pages.";
      }
      {
        # to this host's own address the kernel delivers on lo, so neither listener needs this host in `from`
        assertion =
          cfg.ruler.enable
          -> lib.all (l: l.host == config.networking.hostName) [
            listeners.alertmanager
            listeners.prometheus
          ];
        message = "homelab.loki.ruler: Alertmanager and Prometheus are not served on ${config.networking.hostName}; add it to their sam.fleet.listeners `from` before moving the ruler.";
      }
    ];

    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;
        analytics.reporting_enabled = false;
        server = {
          http_listen_address = cfg.listenAddress;
          http_listen_port = cfg.port;
          grpc_listen_address = "127.0.0.1";
          grpc_listen_port = 9095;
          http_server_read_timeout = "600s";
          http_server_write_timeout = "600s";
        };
        common = {
          path_prefix = dataDir;
          replication_factor = 1;
          # the chart's memberlist ring has one member; in memory needs no gossip port
          instance_addr = "127.0.0.1";
          ring.kvstore.store = "inmemory";
          storage.filesystem = {
            chunks_directory = "${dataDir}/chunks";
            rules_directory = "${dataDir}/rules";
          };
        };
        # must stay identical to what wrote the copied chunks: append a new period, never edit this one
        schema_config.configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "loki_index_";
              period = "24h";
            };
          }
        ];
        limits_config = {
          retention_period = cfg.retention;
          # pi-agent backs the 30-day "Pi agents" panels (devenv-platform#76), harness the 30-day agent usage review,
          # platform the bi-weekly "Platform health" review (pkgs/platform-record/platform_record.py)
          retention_stream = [
            {
              selector = ''{job="platform"}'';
              priority = 1;
              period = "720h";
            }
            {
              selector = ''{job="pi-agent"}'';
              priority = 1;
              period = "720h";
            }
            {
              selector = ''{observer="harness"}'';
              priority = 1;
              period = "720h";
            }
          ];
          ingestion_rate_mb = 8;
          ingestion_burst_size_mb = 16;
          # the chart's defaults, carried so the upgrade changes no query behaviour
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
          max_cache_freshness_per_query = "10m";
          split_queries_by_interval = "15m";
          query_timeout = "300s";
        };
        compactor = {
          working_directory = "${dataDir}/compactor";
          retention_enabled = true;
          delete_request_store = "filesystem";
        };
        # the default ceiling is 4GB, so a large WAL would replay into the 1G MemoryMax in a loop
        ingester.wal.replay_memory_ceiling = "512MB";
        query_range.align_queries_with_step = true;
        tracing.enabled = false;
        # https://grafana.com/docs/loki/latest/configure/#ruler
        ruler = lib.mkIf cfg.ruler.enable {
          # a store path, <tenant>/<file>.yaml, read at start
          storage = {
            type = "local";
            local.directory = "${./monitoring/loki-rules}";
          };
          rule_path = "${dataDir}/ruler";
          ring.kvstore.store = "inmemory";
          alertmanager_url = listeners.alertmanager.url;
          wal.dir = "${dataDir}/ruler-wal";
          remote_write = {
            enabled = true;
            clients.prometheus.url = "${listeners.prometheus.url}/api/v1/write";
          };
        };
      };
    };

    systemd.services.loki = {
      startLimitIntervalSec = 1200;
      startLimitBurst = 3;
      onFailure = [ "loki-failed.service" ];
      environment.GOMEMLIMIT = "900MiB";
      serviceConfig = {
        # /ready waits out the WAL replay and the ingester's 15 s join; local only, like the collector's probe
        ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 90 --retry-delay 2 --retry-all-errors --retry-max-time ${toString probeBudget} http://${probeHost}:${toString cfg.port}/ready";
        TimeoutStartSec = 210;
        TimeoutStopSec = 90;
        RestartSec = 30;
        # the chart's limits
        MemoryMax = "1G";
        CPUQuota = "50%";
        MemorySwapMax = 0;
        ProtectSystem = lib.mkForce "strict";
        ReadWritePaths = [ dataDir ];
        CapabilityBoundingSet = "";
        PrivateDevices = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0027";
      };
    };

    systemd.services.loki-failed = {
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
      };
      script = ''
        ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-all-errors --retry-max-time 60 -H "Priority: high" -d "loki failed on ${config.networking.hostName}" ${lib.escapeShellArg cfg.ntfyUrl}
      '';
    };
  };
}
