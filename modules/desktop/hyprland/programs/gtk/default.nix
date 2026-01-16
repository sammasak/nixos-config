# GTK Configuration
{ pkgs, lib, ... }:
{
  gtk = {
    enable = true;

    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };

    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-decoration-layout = "menu:";
    };

    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = true;
      gtk-decoration-layout = "menu:";
    };
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = lib.mkForce "prefer-dark";
    };
  };

  # Set environment variables for consistent dark mode detection
  home.sessionVariables = {
    GTK_THEME = "Adwaita:dark";
  };

  qt = {
    enable = true;
    platformTheme.name = lib.mkForce "gtk3";
  };
}
