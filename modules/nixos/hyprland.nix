{pkgs, ...}:
{
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  

  programs.hyprland.enable = true;
  programs.firefox.enable = true;  

  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];

  environment.systemPackages = with pkgs; [
    xdg-utils
  ];
}
