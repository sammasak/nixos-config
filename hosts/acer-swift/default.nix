{ config, pkgs, hostName, user, ...}:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/hyprland.nix
    ../../modules/nixos/laptop.nix
  ];

  networking.hostName = hostName;

  users.users.${user} = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager" "video" "audio" ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;


  system.stateVersion = "25.11";  
}
