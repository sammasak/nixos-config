# Shared desktop services (system-wide): xdg portal, thunar file manager, gvfs.
{ config, pkgs, lib, ... }:
{
  config = {
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    # Keep pre-1.17 behavior: use the first portal implementation available.
    xdg.portal.config.common.default = "*";

    programs.thunar.enable = true;
    programs.xfconf.enable = true;
    services.gvfs.enable = true;
  };
}
