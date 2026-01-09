# Desktop profile - Graphical desktop environment with Hyprland
# Use this for workstations and laptops with GUI

{pkgs, ...}:
{
  imports = [
    ../modules/nixos/fonts.nix
    ../modules/nixos/stylix.nix
    ../modules/programs/firefox.nix
    ../modules/programs/vscode.nix
    ../modules/home/waybar.nix
  ];

  # Display manager (SDDM with Wayland)
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

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

  # GVFS for mounting
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
    waybar
    nwg-dock-hyprland
  ];
}
