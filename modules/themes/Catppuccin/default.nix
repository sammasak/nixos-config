{
  config,
  lib,
  pkgs,
  ...
}:
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
      # Qt theming only where there is a desktop (#185). Stylix's Qt target auto-enables under NixOS
      # and, without a desktop's platform theme, falls back to qtct + a Kvantum theme: a headless boot
      # has no Qt GUI to theme, and that ~/.config/Kvantum tree failed msi-ms7758's Home Manager
      # activation. Desktops (sam.desktop.enable) keep it, unchanged.
      qt.enable = lib.mkDefault (config.sam.desktop.enable or false);
    };
  };

  # the Home Manager half of the same gate; a host with Stylix off (roles/rf-lab.nix) has no
  # Home Manager stylix options, so it gets nothing here
  home-manager.sharedModules = lib.mkIf config.stylix.enable [
    { stylix.targets.qt.enable = lib.mkDefault (config.sam.desktop.enable or false); }
  ];
}
