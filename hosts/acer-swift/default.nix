{ config, pkgs, hostName, user, ...}:
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Stylix theming
  stylix = {
    image = "${pkgs.nixos-artwork.wallpapers.nineish-dark-gray.gnomeFilePath}";
    polarity = "dark";
    enable = true;
  };

  # SDDM display manager
  services.displayManager.sddm = {
    enable = true;
    theme = "sugar-candy";
  };

  environment.systemPackages = with pkgs; [
    sddm-sugar-candy
  ];

  # Custom SDDM theme configuration to match Hyprlock
  xdg.configFile."sddm/themes/sugar-candy/theme.conf".text = ''
    [General]
    Background=${pkgs.nixos-artwork.wallpapers.nineish-dark-gray.gnomeFilePath}
    BackgroundMode=wallpaper
    BackgroundBlur=true
    FormPosition=center
    Font=JetBrains Mono
    ForceHideCompletePassword=true
    HeaderText=Welcome back, $USER
    DateFormat=dddd, MMMM d
  '';

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
