# Stylix - Unified theming system
# Provides consistent colors, fonts, and styling across all applications

{pkgs, ...}:
{
  stylix = {
    enable = true;

    # Wallpaper (required by Stylix)
    image = ../home/wallpapers/wallpaper.jpg;

    base16Scheme = "${pkgs.base16-schemes}/share/themes/selenized-black.yaml";

    # Font configuration
    fonts = {
      # Monospace font for terminals and code editors
      monospace = {
        package = pkgs.jetbrains-mono;
        name = "JetBrains Mono";
      };

      # Sans-serif font for UI elements
      sansSerif = {
        package = pkgs.noto-fonts;
        name = "Noto Sans";
      };

      # Serif font for documents
      serif = {
        package = pkgs.noto-fonts;
        name = "Noto Serif";
      };

      # Emoji font
      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };

      # Base font size
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
