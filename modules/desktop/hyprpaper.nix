# Hyprpaper - Wallpaper daemon for Hyprland

{ pkgs, ... }:
let
  theme = import ../../lib/theme.nix;
in
{
  services.hyprpaper = {
    enable = true;

    settings = {
      splash = false;
      preload = [ "${theme.wallpaper}" ];
      wallpaper = [ ",${theme.wallpaper}" ];
    };
  };
}
