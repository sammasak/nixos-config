# Stylix - Unified theming system
# Provides consistent colors, fonts, and styling across all applications

{ pkgs, ... }:
let
  theme = import ../lib/theme.nix;
in
{
  stylix = {
    enable = true;

    # Wallpaper (from shared theme config)
    image = theme.wallpaper;

    base16Scheme = "${pkgs.base16-schemes}/share/themes/selenized-black.yaml";

    # Font configuration
    fonts = {
      monospace = {
        package = pkgs.jetbrains-mono;
        name = theme.fonts.mono;
      };

      sansSerif = {
        package = pkgs.noto-fonts;
        name = theme.fonts.sans;
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
        terminal = 11;
        applications = 11;
        desktop = 11;
        popups = 11;
      };
    };

    # Cursor theme
    cursor = {
      package = pkgs.phinger-cursors;
      name = "phinger-cursors";
      size = 24;
    };

    # Opacity settings
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
