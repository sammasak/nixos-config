# node-exporter on the host's fleet address, for black-pi's Prometheus alone (modules/homelab/monitoring/prometheus.nix
# scrapes every host in sam.fleet.hosts; its firewall rule is the host's node-exporter listener there). The address is
# reachable through the trusted interfaces too, whatever that rule admits.
{
  config,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) hosts;
  textfiles = "/run/node-exporter-textfile";
in
{
  imports = [ ./gpu-exporter.nix ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = hosts.${config.networking.hostName}.address;
    # a host's own checks drop *.prom files here (open-webui.nix's edge-socket check, the generation below)
    extraFlags = [ "--collector.textfile.directory=${textfiles}" ];
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
}
