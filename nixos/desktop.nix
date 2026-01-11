# Desktop NixOS configuration (Hyprland)
{ pkgs, ... }:
{
  imports = [ ../modules/fonts.nix ../modules/stylix.nix ];

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "sugar-dark";
  };

  programs.hyprland.enable = true;
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;

  programs.thunar.enable = true;
  programs.xfconf.enable = true;
  services.gvfs.enable = true;

  environment.systemPackages = with pkgs; [
    xdg-utils wl-clipboard grim slurp brightnessctl
    pavucontrol playerctl nwg-dock-hyprland hyprpicker sddm-sugar-dark
  ];
}
