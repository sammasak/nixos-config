{config, pkgs, ...}:
{
  imports = [
    # Base configuration
    ../../modules/home/base.nix

    # Hyprland and related UI components
    ../../modules/home/desktop/hyprland
    ../../modules/home/kitty.nix
    ../../modules/home/rofi.nix
    ../../modules/home/dunst.nix
    ../../modules/home/hyprlock.nix
    ../../modules/home/hypridle.nix
    ../../modules/home/ironbar.nix
    ../../modules/home/gtk.nix
  ];

  home.username = "lukas";
  home.homeDirectory = "/home/lukas";
  home.stateVersion = "25.11";

}
