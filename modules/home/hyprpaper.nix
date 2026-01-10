# Hyprpaper - Wallpaper daemon for Hyprland
# Based on AlexNabokikh/nix-config

{pkgs, ...}:
let
  wallpaper = ./wallpapers/wallpaper.jpg;
in
{
  services.hyprpaper = {
    enable = true;

    settings = {
      splash = false;
      preload = [ "${wallpaper}" ];
      wallpaper = [ ",${wallpaper}" ];
    };
  };
}
