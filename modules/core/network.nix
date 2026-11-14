{
  config,
  pkgs,
  lib,
  ...
}:
let
  profile = config.sam.profile;
  hasDesktop = config.sam.desktop.enable;
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall anySourceTcp;
  openSsh = anySourceTcp config.networking.firewall config.services.openssh.ports;

  sshRules = mkDualBackendFirewall {
    nftComment = "Allow SSH only from LAN subnet and loopback (nftables backend).";
    ports = config.services.openssh.ports;
    sources = [ config.sam.fleet.lanCidr ];
    interfaces = [ "lo" ];
    # nftables path only, and inert on the iptables backend running today,
    # where nixos-fw's default refuse already covers it.
    dropOthers = true;
    backend = config.networking.firewall.backend;
  };
in
{
  networking = {
    hostName = profile.hostname;
    networkmanager.enable = true;

    # Baseline firewall for EVERY host: SSH only. Cluster ingress ports live in
    # modules/homelab/k3s/default.nix behind `homelab.k3s.enable`, so a laptop
    # that never joins the cluster ends up SSH-only.
    #
    # Break-glass if a rule here is ever wrong: the k8s API (root pod) path, or
    # the console.
    firewall = {
      enable = true;
      inherit (sshRules) extraInputRules extraCommands;
    };
  };

  services.openssh.openFirewall = false;

  assertions = [
    {
      assertion = !config.services.openssh.openFirewall && openSsh == [ ];
      message = "modules/core/network.nix: SSH reaches the LAN only through the scoped rule there; keep services.openssh.openFirewall = false and sshd port(s) ${toString openSsh} out of networking.firewall allowedTCPPorts and allowedTCPPortRanges, global and per interface, which accept from any source.";
    }
  ];

  environment.systemPackages = lib.optionals hasDesktop [ pkgs.networkmanagerapplet ];
}
