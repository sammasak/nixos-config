# Desktop profile - Complete Hyprland desktop environment
# Includes both system-level (drivers, audio) and user-level (apps, dotfiles)
#
# System: Hyprland, PipeWire, SDDM, fonts, Stylix
# User: kitty, waybar, rofi, swaync, firefox, vscode, shell tools

{ pkgs, user, ... }:
{
  imports = [
    ../modules/fonts.nix
    ../modules/stylix.nix
  ];

  # === SYSTEM-LEVEL ===

  # Display manager
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "sugar-dark";
  };

  # Hyprland window manager
  programs.hyprland.enable = true;

  # XDG Desktop Portal for Wayland
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];

  # PipeWire audio
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  # Graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # File management
  programs.thunar.enable = true;
  programs.xfconf.enable = true;
  services.gvfs.enable = true;

  # Desktop utilities
  environment.systemPackages = with pkgs; [
    xdg-utils
    wl-clipboard
    grim
    slurp
    brightnessctl
    pavucontrol
    playerctl
    nwg-dock-hyprland
    hyprpicker
    sddm-sugar-dark  # Login screen theme
  ];

  # === USER-LEVEL (home-manager) ===

  home-manager.users.${user} = {
    home.username = user;
    home.homeDirectory = "/home/${user}";
    home.stateVersion = "25.11";

    imports = [
      # Shell (shared with server profile)
      ../modules/shell/nushell.nix
      ../modules/shell/starship.nix
      ../modules/shell/git.nix
      ../modules/shell/cli-tools.nix

      # Desktop environment
      ../modules/desktop/hyprland
      ../modules/desktop/hyprlock.nix
      ../modules/desktop/hypridle.nix
      ../modules/desktop/hyprpaper.nix
      ../modules/desktop/gtk.nix

      # Apps (swappable)
      ../modules/terminals/kitty.nix
      ../modules/bars/waybar.nix
      ../modules/launchers/rofi.nix
      ../modules/notifications/swaync.nix
      ../modules/browsers/firefox.nix
      ../modules/editors/vscode.nix
    ];
  };
}
