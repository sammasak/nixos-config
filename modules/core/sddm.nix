# SDDM display manager
{ pkgs, lib, host, ... }:
let
  inherit (import ../../hosts/${host}/variables.nix) sddmTheme;
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
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    enableHidpi = true;
    autoNumlock = true;
    package = lib.mkForce pkgs.kdePackages.sddm;
    extraPackages = sddmDependencies;
    settings.Theme.CursorTheme = "Bibata-Modern-Classic";
    theme = "sddm-astronaut-theme";
  };

  environment.systemPackages = sddmDependencies ++ [ pkgs.bibata-cursors ];
}
