# node-exporter on the host's fleet address, for black-pi's Prometheus alone (modules/homelab/monitoring/prometheus.nix
# scrapes every host in sam.fleet.hosts; its firewall rule is the host's node-exporter listener there). The address is
# reachable through the trusted interfaces too, whatever that rule admits.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) hosts;
  host = config.networking.hostName;
  listener = "node-exporter-${host}";
  # a host off the fleet has no address and no listener: the assertion below says so, instead of an attribute error
  served = config.sam.fleet.listeners ? ${listener};
  textfiles = "/run/node-exporter-textfile";
in
{
  imports = [ ./gpu-exporter.nix ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = lib.mkIf served hosts.${host}.address;
    port = lib.mkIf served config.sam.fleet.listeners.${listener}.port;
    # a host's own checks drop *.prom files here (open-webui.nix's edge-socket check, the generation below)
    extraFlags = [
      "--collector.textfile.directory=${textfiles}"
      "--collector.systemd.enable-restarts-metrics"
    ];
    # needs AF_UNIX for D-Bus (upstream adds it); black-pi keeps only the failed unit_state series (prometheus.nix)
    enabledCollectors = [ "systemd" ];
  };
  systemd.tmpfiles.rules = [ "d ${textfiles} 0755 root root -" ];

  # `|| true`: a failed write must not fail the activation, and so a deploy
  system.activationScripts.nixosTextfile.text = ''
    ${pkgs.bash}/bin/bash ${../../../scripts/nixos-textfile.sh} ${textfiles} "$systemConfig" /nix/var/nix/profiles || true
  '';

  # DHCP: the address can appear after the unit, so it waits for the network and retries below the start limit
  systemd.services.prometheus-node-exporter = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      RestartSec = 5;
      MemoryMax = "64M";
    };
  };

  assertions = [
    {
      assertion = served;
      message = "modules/homelab/monitoring/node-exporter.nix: ${host} has no sam.fleet listener ${listener} (modules/core/fleet.nix generates one per sam.fleet host): import this module on fleet hosts only, or add the host to sam.fleet.hosts.";
    }
  ];
}
