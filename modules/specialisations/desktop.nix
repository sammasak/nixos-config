# Desktop specialisation (boot-time GUI mode)
# Adds Hyprland, SDDM, themes, and GUI applications to base server config.
{ pkgs, ... }:
{
  imports = [
    ../desktop/hyprland
    ../core/sddm.nix
    ../themes/Catppuccin
  ];

  # Specialisation metadata
  specialisation.desktop.inheritParentConfig = true;

  # Enable X server for compatibility (some apps need it)
  services.xserver.enable = true;

  # GUI applications (installed only in desktop mode)
  environment.systemPackages = with pkgs; [
    # These will be moved from core packages later
  ];
}
