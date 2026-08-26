# Desktop configuration (now the default boot mode)
# Adds Hyprland, SDDM, and GUI applications
{ pkgs, ... }:
{
  imports = [
    ../desktop/hyprland
    ../core/sddm.nix
    # Catppuccin theme now in base role for GRUB theming
  ];

  # Enable X server for compatibility (some apps need it)
  services.xserver.enable = true;

  # GUI applications (installed in desktop mode)
  environment.systemPackages = with pkgs; [
    # These will be moved from core packages later
  ];
}
