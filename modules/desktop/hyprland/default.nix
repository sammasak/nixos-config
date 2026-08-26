# Hyprland desktop (system-wide)
{ config, pkgs, lib, ... }:
{
  config = {
    programs.hyprland.enable = true;
    programs.hyprland.xwayland.enable = true;
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    # Keep pre-1.17 behavior: use the first portal implementation available.
    xdg.portal.config.common.default = "*";
    services.displayManager.defaultSession = lib.mkDefault "hyprland";

    programs.thunar.enable = true;
    programs.xfconf.enable = true;
    services.gvfs.enable = true;
  };
}
