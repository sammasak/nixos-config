# Shared desktop services (system-wide): xdg portal, thunar file manager, gvfs.
{ pkgs, ... }:
{
  config = {
    xdg.portal.enable = true;
    # Keep pre-1.17 behavior: use the first portal implementation available.
    xdg.portal.config.common.default = "*";

    programs.thunar.enable = true;
    programs.xfconf.enable = true;
    services.gvfs.enable = true;
  };
}
