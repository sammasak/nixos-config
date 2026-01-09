# GTK Configuration
# Stylix handles: theme, cursor, fonts
# This module: icon theme and GTK-specific settings

{pkgs, ...}:
{
  gtk = {
    enable = true;

    # Icon theme (not handled by Stylix)
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };

    # GTK behavior settings
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-decoration-layout = "menu:";
    };

    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-decoration-layout = "menu:";
    };
  };

  home.packages = with pkgs; [
    papirus-icon-theme
  ];
}
