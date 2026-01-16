# Hyprland desktop (system-wide)
{ pkgs, lib, ... }:
{
  programs.hyprland.enable = true;
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
  services.displayManager.defaultSession = lib.mkDefault "hyprland";

  programs.thunar.enable = true;
  programs.xfconf.enable = true;
  services.gvfs.enable = true;
}
