# Alertmanager on black-pi through upstream services.prometheus.alertmanager: one route and its inhibitions,
# one webhook to lenovo's alert-bridge, which pages homelab-alerts. Upstream passes the file through envsubst, so a literal `$` must be written `$$`.
{ config, lib, ... }:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  cfg = config.services.prometheus.alertmanager;
  fw = config.networking.firewall;
  hostOff = [ "alertname = HostExpectedOff" ];
  # the shipping policy's quiet hours, in UTC: a location would need tzdata where amtool checks the file. 19:00 to
  # 07:30 covers 21:00 to 08:30 Stockholm in both seasons, and mutes one more hour: 20:00 to 21:00 in winter (CET),
  # 08:30 to 09:30 in summer (CEST)
  quiet = (lib.importJSON ./shipping-policy.json).notify;
  clock =
    h:
    let
      m = builtins.floor (h * 60.0);
    in
    "${lib.fixedWidthNumber 2 (m / 60)}:${lib.fixedWidthNumber 2 (lib.mod m 60)}";
  from = clock quiet.quietFromUtcHour.value;
  until = clock quiet.quietUntilUtcHour.value;
  night =
    assert lib.assertMsg (
      from != until
    ) "shipping-policy.json: notify's quiet hours start and end at ${from}";
    if quiet.quietFromUtcHour.value > quiet.quietUntilUtcHour.value then
      [
        {
          start_time = from;
          end_time = "24:00";
        }
        {
          start_time = "00:00";
          end_time = until;
        }
      ]
    else
      [
        {
          start_time = from;
          end_time = until;
        }
      ];
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
          # shipping alerts (rules/shipping.nix) wait for the morning; one firing then is sent when the night ends
          {
            receiver = "alert-bridge";
            matchers = [ ''team = "shipping"'' ];
            mute_time_intervals = [ "night" ];
          }
        ];
      };
      time_intervals = [
        {
          name = "night";
          time_intervals = [ { times = night; } ];
        }
      ];
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
        # (./rules/homelab.yaml, ./rules/homelab.nix), silence what it causes. With a host that does not sleep down, it does not fire.
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
        # 3) GpuTelemetryDown is the per-host page for a dead GPU exporter: its TargetDown would say it twice
        {
          source_matchers = [ "alertname = GpuTelemetryDown" ];
          target_matchers = [
            "alertname = TargetDown"
            ''job = "nvidia-gpu"''
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
