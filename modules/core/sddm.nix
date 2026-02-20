# SDDM display manager
{ config, pkgs, lib, ... }:
let
  desktop = config.sam.profile.desktop;
  displayManager = config.sam.profile.displayManager;
  sddmTheme = config.sam.profile.sddmTheme;
  sddm-astronaut = pkgs.sddm-astronaut.override {
    embeddedTheme = "${sddmTheme}";
    themeConfig = {
      PartialBlur = "false";
      FormPosition = "center";
    };
  };
  sddmDependencies = [
    sddm-astronaut
    pkgs.kdePackages.qtsvg
    pkgs.kdePackages.qtmultimedia
    pkgs.kdePackages.qtvirtualkeyboard
  ];
in
{
  config = lib.mkIf (displayManager == "sddm") {
    services.displayManager.sddm = {
      enable = true;
      # Keep the greeter on X11 for stability on legacy GPUs.
      wayland.enable = lib.mkDefault (desktop == "hyprland");
      enableHidpi = true;
      autoNumlock = true;
      package = lib.mkForce pkgs.kdePackages.sddm;
      extraPackages = sddmDependencies;
      settings.Theme.CursorTheme = "Bibata-Modern-Classic";
      theme = "sddm-astronaut-theme";
    };

    environment.systemPackages = sddmDependencies ++ [ pkgs.bibata-cursors ];
  };
}
