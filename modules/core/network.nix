{ config, pkgs, lib, ... }:
let
  profile = config.sam.profile;
  hasDesktop = config.sam.desktop.enable;
in
{
  networking = {
    hostName = profile.hostname;
    networkmanager.enable = true;

    # Baseline firewall for EVERY host: SSH only. Cluster ingress ports live in
    # modules/homelab/k3s/default.nix behind `homelab.k3s.enable`, so a laptop
    # that never joins the cluster ends up SSH-only.
    firewall = {
      enable = true;
      # SSH scoped to LAN + loopback, through BOTH backends. Writing only the
      # nftables rule left SSH silently world-open to anything routable, because
      # this tree runs the iptables backend. Break-glass if a rule is wrong: the
      # k8s API (root pod) path, or the console.
      extraInputRules = ''
        # Allow SSH only from LAN subnet and loopback (nftables backend).
        iifname "lo" tcp dport 22 accept
        ip saddr ${profile.lanCidr} tcp dport 22 accept
        tcp dport 22 drop
      '';
      extraCommands = lib.optionalString (config.networking.firewall.backend == "iptables") ''
        ip46tables -w -A nixos-fw -i lo -p tcp --dport 22 -j nixos-fw-accept
        iptables -w -A nixos-fw -s ${profile.lanCidr} -p tcp --dport 22 -j nixos-fw-accept
      '';
    };
  };

  # 22 must not enter allowedTCPPorts (any-source accept) — the scoped
  # accepts above are the only SSH path besides trusted interfaces.
  services.openssh.openFirewall = false;

  environment.systemPackages = with pkgs; [
  ] ++ lib.optionals hasDesktop [
    networkmanagerapplet
  ];
}
