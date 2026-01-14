# GTK Configuration
# Stylix handles: theme, cursor, fonts
# This module: icon theme and GTK-specific settings

{pkgs, lib, ...}:
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

  # Set system color scheme to dark (override Stylix)
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = lib.mkForce "prefer-dark";
    };
  };

  # Qt theme configuration - let Stylix handle qt.style, but set platform theme
  qt = {
    enable = true;
    platformTheme.name = lib.mkForce "gtk3";
  };
}
