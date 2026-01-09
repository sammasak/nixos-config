{ config, pkgs, hostName, user, ...}:
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Networking
  networking.hostName = hostName;

  # User configuration
  users.users.${user} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager" "video" "audio" ];
  };

  # Boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Intel thermal management
  services.thermald.enable = true;

  # NixOS state version (do not change after installation)
  system.stateVersion = "25.11";
}
