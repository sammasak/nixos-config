# Loki as a host service through upstream services.loki, at parity with the k3s chart (single binary, filesystem,
# tsdb v13, 72h with 30 days for the two agent telemetry streams), so logs stay queryable when the cluster is not.
# The data directory keeps the chart's layout under /var/loki (chunks, rules, compactor, the rest under
# path_prefix), so the cut-over in docs/k3s-to-nixos-native.md ("P4 in detail") is a copy of that directory.
# Upstream runs `loki -verify-config` on the rendered file at build time (only while extraFlags is empty).
{ config, lib, pkgs, ... }:
let
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
  cfg = config.homelab.loki;
  dataDir = config.services.loki.dataDir;
  probeHost = if cfg.listenAddress == "0.0.0.0" then "127.0.0.1" else cfg.listenAddress;

  firewallRules = mkDualBackendFirewall {
    nftComment = "loki: push and query from the listed sources.";
    ports = [ cfg.port ];
    sources = cfg.allowedSources;
    interfaces = [ ];
    backend = config.networking.firewall.backend;
  };
in
{
  options.homelab.loki = {
    enable = lib.mkEnableOption "Grafana Loki as a host service";
    listenAddress = lib.mkOption {
      type = lib.types.strMatching "[0-9]+(\\.[0-9]+){3}";
      default = "127.0.0.1";
      description = "IPv4 address of the HTTP API (push and query). gRPC stays on loopback.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "HTTP port.";
    };
    retention = lib.mkOption {
      type = lib.types.strMatching "[0-9]+[hdw]";
      default = "72h";
      description = "Default retention; the two agent telemetry streams keep 720h regardless.";
    };
    allowedSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.168.10.0/24" ];
      description = "IPv4 addresses or CIDRs admitted to the port; empty opens nothing.";
    };
    ntfyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ntfy topic URL paged when Loki fails; null, no page.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.allowedSources != [ ] -> !lib.hasPrefix "127." cfg.listenAddress;
      message = "homelab.loki.allowedSources: listenAddress ${cfg.listenAddress} is loopback, so nothing the firewall admits can reach Loki.";
    }];

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
        schema_config.configs = [{
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = { prefix = "loki_index_"; period = "24h"; };
        }];
        limits_config = {
          retention_period = cfg.retention;
          retention_stream = [
            { selector = ''{job="pi-agent"}''; priority = 1; period = "720h"; }
            { selector = ''{observer="harness"}''; priority = 1; period = "720h"; }
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
        query_range.align_queries_with_step = true;
        tracing.enabled = false;
      };
    };

    systemd.services.loki = {
      # 3 starts of at most 210 + 30 s each fit in the window, so a start loop reaches failed and pages
      startLimitIntervalSec = 900;
      startLimitBurst = 3;
      onFailure = lib.optional (cfg.ntfyUrl != null) "loki-failed.service";
      serviceConfig = {
        # /ready waits out the WAL replay and the ingester's 15 s join; local only, like the collector's probe
        ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 90 --retry-delay 2 --retry-connrefused --retry-all-errors --retry-max-time 180 http://${probeHost}:${toString cfg.port}/ready";
        TimeoutStartSec = 210;
        RestartSec = 30;
        # the chart's limit
        MemoryMax = "1G";
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
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        UMask = "0027";
      };
    };

    systemd.services.loki-failed = lib.mkIf (cfg.ntfyUrl != null) {
      serviceConfig = { Type = "oneshot"; DynamicUser = true; };
      script = ''
        ${pkgs.curl}/bin/curl -fsS -m 10 -H "Priority: high" -d "loki failed on ${config.networking.hostName}" ${lib.escapeShellArg cfg.ntfyUrl}
      '';
    };

    networking.firewall = lib.mkIf (cfg.allowedSources != [ ]) {
      inherit (firewallRules) extraInputRules extraCommands;
    };
  };
}
