# Network configuration
{ host, pkgs, ... }:
let
  inherit (import ../../hosts/${host}/variables.nix) hostname;
in
{
  networking = {
    hostName = "${hostname}";
    networkmanager.enable = true;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        22    # SSH
        80    # HTTP
        443   # HTTPS
        8080  # Alternative HTTP
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    networkmanagerapplet
  ];
}
