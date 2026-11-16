# Alertmanager on black-pi through upstream services.prometheus.alertmanager: one route and its inhibitions,
# one webhook to lenovo's alert-bridge, which pages homelab-alerts. Upstream passes the file through envsubst, so a literal `$` must be written `$$`.
{ config, lib, ... }:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  cfg = config.services.prometheus.alertmanager;
  fw = config.networking.firewall;
  hostOff = [ "alertname = HostExpectedOff" ];
in
{
  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = hosts.${config.networking.hostName}.address;
    # one instance: no gossip listener on 9094
    extraFlags = [ "--cluster.listen-address=" ];
    configuration = {
      global.resolve_timeout = "5m";
      route = {
        group_by = [
          "namespace"
          "alertname"
          "severity"
        ];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "12h";
        receiver = "alert-bridge";
        # Watchdog pages no one: lenovo's cluster-watchdog reads it from /api/v2/alerts
        routes = [
          {
            receiver = "null";
            matchers = [ ''alertname =~ "Watchdog|InfoInhibitor|HostExpectedOff"'' ];
          }
        ];
      };
      receivers = [
        { name = "null"; }
        {
          name = "alert-bridge";
          webhook_configs = [
            {
              url = "http://${hosts.lenovo-21CB001PMX.address}:9099/notify";
              send_resolved = true;
            }
          ];
        }
      ];
      inhibit_rules = [
        {
          source_matchers = [ "severity = critical" ];
          target_matchers = [ "severity =~ warning|info" ];
          equal = [
            "namespace"
            "alertname"
          ];
        }
        {
          source_matchers = [ "severity = warning" ];
          target_matchers = [ "severity = info" ];
          equal = [
            "namespace"
            "alertname"
          ];
        }
        # Planned power-off of a sleeping host (homelab-gitops#188): while HostExpectedOff fires for it
        # (./rules/homelab.yaml), silence what it causes. With a host that does not sleep down, it does not fire.
        # 1) anything labelled with that host;
        {
          source_matchers = hostOff;
          target_matchers = [ ''node =~ ".+"'' ];
          equal = [ "node" ];
        }
        # 2) TargetDown of a job with a target on every host, or only on sleeping ones (nvidia-gpu: asus), which
        #    carries no node label. A new per-host job needs adding here.
        {
          source_matchers = hostOff;
          target_matchers = [
            "alertname = TargetDown"
            ''job =~ "node-exporter|nvidia-gpu"''
          ];
        }
      ];
    };
  };

  systemd.services.alertmanager.serviceConfig = {
    RestartSec = 10;
    MemoryMax = "64M";
  };

  # lenovo's watchdog reads /-/ready and the Watchdog alert; Prometheus on this host arrives on loopback
  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "Alertmanager answers the watchdog on lenovo.";
        ports = [ cfg.port ];
        sources = [ hosts.lenovo-21CB001PMX.address ];
        interfaces = [ ];
        inherit (fw) backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  assertions = [
    {
      assertion = !cfg.openFirewall && fw.enable && anySourceTcp fw [ cfg.port ] == [ ];
      message = "modules/homelab/monitoring/alertmanager.nix: Alertmanager has no authentication; keep the firewall on and port ${toString cfg.port} out of openFirewall and allowedTCPPorts.";
    }
  ];
}
