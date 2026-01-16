# Catppuccin Mocha Theme - Stylix configuration
{ pkgs, ... }:
let
  wallpaper = ../../../assets/wallpapers/train-sideview.webp;
in
{
  stylix = {
    enable = true;

    image = wallpaper;

    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";

    fonts = {
      monospace = {
        package = pkgs.jetbrains-mono;
        name = "JetBrains Mono";
      };

      sansSerif = {
        package = pkgs.noto-fonts;
        name = "Noto Sans";
      };

      serif = {
        package = pkgs.noto-fonts;
        name = "Noto Serif";
      };

      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };

      sizes = {
        terminal = 10;
        applications = 10;
        desktop = 10;
        popups = 9;
      };
    };

    cursor = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 24;
    };

    opacity = {
      terminal = 0.95;
      popups = 0.95;
    };

    targets = {
      gtk.enable = true;
      gnome.enable = false;
    };
  };
}
