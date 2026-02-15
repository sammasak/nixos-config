# i3 desktop (system-wide, X11)
{ config, pkgs, lib, ... }:
{
  config = lib.mkIf (config.sam.profile.desktop == "i3") {
    services.xserver = {
      enable = true;

      windowManager.i3 = {
        enable = true;
        extraPackages = with pkgs; [
          dmenu
          i3status
          i3lock
          xterm
        ];
      };
    };

    # Prefer the i3 X11 session when this desktop is selected.
    services.displayManager.defaultSession = lib.mkDefault "none+i3";

    # Provide a lightweight graphical file manager similar to the Hyprland stack.
    programs.thunar.enable = true;
    programs.xfconf.enable = true;
    services.gvfs.enable = true;

    # X11-friendly portal for file pickers etc.
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    # Keep pre-1.17 behavior: use the first portal implementation available.
    xdg.portal.config.common.default = "*";
  };
}
