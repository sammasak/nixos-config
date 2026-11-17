# node-exporter on the host's fleet address, for black-pi's Prometheus alone (modules/homelab/monitoring/prometheus.nix
# scrapes every host in sam.fleet.hosts). The address is reachable through the trusted interfaces too, whatever the
# rule below admits; upstream's openFirewall would admit any source.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  cfg = config.services.prometheus.exporters.node;
  fw = config.networking.firewall;
  textfiles = "/run/node-exporter-textfile";
in
{
  imports = [ ./gpu-exporter.nix ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = hosts.${config.networking.hostName}.address;
    # a host's own checks drop *.prom files here (open-webui.nix's edge-socket check, the generation below)
    extraFlags = [ "--collector.textfile.directory=${textfiles}" ];
    # failed units and timers over D-Bus; black-pi keeps only the failed unit_state series (prometheus.nix)
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

  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "node-exporter answers black-pi's Prometheus.";
        ports = [ cfg.port ];
        sources = [ hosts.black-pi.address ];
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
      message = "modules/homelab/monitoring/node-exporter.nix: keep the firewall on and port ${toString cfg.port} out of openFirewall and allowedTCPPorts; only black-pi is admitted.";
    }
  ];
}
