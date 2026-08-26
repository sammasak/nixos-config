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
      # CAVEAT: `extraInputRules` is implemented ONLY by the nftables firewall
      # backend (firewall-nftables.nix is gated on
      # `networking.firewall.backend == "nftables"`). This tree still runs the
      # iptables backend because `networking.nftables.enable` is false, so the
      # rule below is currently INERT — SSH is reachable from anything that can
      # route to the host, not just the LAN. Making it bite needs either
      # `networking.nftables.enable = true` (must be verified live against
      # Cilium and k3s, `nix eval` cannot prove it) or
      # `services.openssh.openFirewall = false` plus scoped `extraCommands`
      # accepts. Both risk locking the headless node out, so they are left for a
      # supervised change; the rule stays so the intent survives the flip.
      extraInputRules = ''
        # Allow SSH only from LAN subnet and loopback.
        iifname "lo" tcp dport 22 accept
        ip saddr ${profile.lanCidr} tcp dport 22 accept
        tcp dport 22 drop
      '';
    };
  };

  environment.systemPackages = with pkgs; [
  ] ++ lib.optionals hasDesktop [
    networkmanagerapplet
  ];
}
