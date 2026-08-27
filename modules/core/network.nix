{ config, pkgs, lib, ... }:
let
  profile = config.sam.profile;
  hasDesktop = config.sam.desktop.enable;
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;

  sshRules = mkDualBackendFirewall {
    nftComment = "Allow SSH only from LAN subnet and loopback (nftables backend).";
    ports = [ 22 ];
    sources = [ profile.lanCidr ];
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

  # 22 must not enter allowedTCPPorts (any-source accept) — the scoped
  # accepts above are the only SSH path besides trusted interfaces.
  services.openssh.openFirewall = false;

  environment.systemPackages = lib.optionals hasDesktop [ pkgs.networkmanagerapplet ];
}
