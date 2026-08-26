# Network configuration
{ config, pkgs, lib, ... }:
let
  profile = config.sam.profile;
  hasDesktop = config.sam.desktop.enable;
in
{
  networking = {
    hostName = profile.hostname;
    networkmanager.enable = true;

    # Baseline firewall for EVERY host: SSH only.
    #
    # HTTP/HTTPS (80/443/8080) used to be opened here unconditionally. Those are
    # cluster ingress ports and belong to the k3s path, so they now live in
    # modules/homelab/k3s/default.nix behind `homelab.k3s.enable`. A plain
    # desktop laptop that never joins the cluster therefore ends up SSH-only.
    firewall = {
      enable = true;
      # SSH is scoped to LAN + loopback + tailnet through BOTH firewall
      # backends (2026-08-26): `extraInputRules` covers a future nftables
      # backend; `extraCommands` covers the iptables backend that is live
      # today (the nftables-only rule alone was silently INERT — SSH was
      # world-open to anything routable). `services.openssh.openFirewall`
      # is disabled below so 22 never lands in allowedTCPPorts' any-source
      # accept; tailscale0 sits in trustedInterfaces, so tailnet SSH is
      # unaffected. Break-glass if a rule is ever wrong: the k8s API
      # (root pod) path, or the console.
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
