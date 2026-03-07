# Server specialisation (boot-time headless mode)
# Disables GUI components for optimized headless operation
{ lib, ... }:
{
  # Disable desktop components
  programs.hyprland.enable = lib.mkForce false;
  services.displayManager.sddm.enable = lib.mkForce false;
  services.xserver.enable = lib.mkForce false;

  # Specialisation metadata
  specialisation.server.inheritParentConfig = true;
}
