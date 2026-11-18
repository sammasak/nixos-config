# The shipping collector (scripts/shipping-metrics.py, docs/shipping.md) on the deployer: every 30 min it reads GitHub
# as the owner's user, whose gh login the coordinator's tasks already use (no token of its own; without one it counts
# public repos only, says so, and measures PR lead time from the PR's open time), and the platform records in Loki, and leaves one textfile for this host's
# node-exporter. A failed source keeps its stale timestamp, which ShippingCollectorStale alerts on; the unit has no
# Restart, so an outage never loops. The dashboards check (flake-modules/grafana-dashboards-check.nix) takes the series
# names from `scripts/shipping-metrics.py --list`: a series the shipping dashboard reads must be in that list.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) deployer hosts loki;
  dir = "/var/lib/shipping-metrics";
  user = config.sam.profile.username;
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];

  systemd.services.shipping-metrics = {
    description = "Shipping metrics from GitHub and the platform records, for node-exporter";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.gh ];
    environment.HOME = "/home/${user}";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.python3)
        "-I"
        "${../../scripts/shipping-metrics.py}"
        "--policy"
        "${./monitoring/shipping-policy.json}"
        "--out"
        "${dir}/shipping.prom"
        "--owner"
        config.sam.userConfig.git.userName
        "--deploy-repo"
        "nixos-config"
        "--loki"
        loki.url
        "--hostnames"
        (lib.concatStringsSep "," (lib.attrNames hosts))
      ];
      StateDirectory = "shipping-metrics";
      StateDirectoryMode = "0755";
      # above the script's own 240 s deadline
      TimeoutStartSec = 300;
      # 43 MB peak in a run against the real API; lenovo's sam.memory budget has no room for more
      MemoryMax = "96M";
      Nice = 10;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
  systemd.timers.shipping-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:07,37";
      Persistent = true;
    };
  };

  assertions = [
    {
      assertion = config.networking.hostName == deployer;
      message = "modules/homelab/shipping-metrics.nix: modules/homelab/monitoring/rules/shipping.nix pages on the collector of sam.fleet.deployer (${deployer}); import it there alone.";
    }
  ];
}
