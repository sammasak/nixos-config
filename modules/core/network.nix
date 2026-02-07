# Network configuration
{ config, pkgs, ... }:
let
  profile = config.sam.profile;
in
{
  networking = {
    hostName = profile.hostname;
    networkmanager.enable = true;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        80    # HTTP
        443   # HTTPS
        8080  # Alternative HTTP
      ];
      extraInputRules = ''
        # Allow SSH only from LAN subnet and loopback.
        iifname "lo" tcp dport 22 accept
        ip saddr ${profile.lanCidr} tcp dport 22 accept
        tcp dport 22 drop
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    networkmanagerapplet
  ];
}
