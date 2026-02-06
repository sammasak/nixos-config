# Network configuration
{ host, pkgs, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
  inherit (vars) hostname;
  lanCidr = vars.lanCidr or "192.168.10.0/24";
in
{
  networking = {
    hostName = "${hostname}";
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
        ip saddr ${lanCidr} tcp dport 22 accept
        tcp dport 22 drop
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    networkmanagerapplet
  ];
}
