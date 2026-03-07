# Laptop-specific configuration
{ lib, ... }:
{
  imports = [
    ../hardware/thermal.nix
  ];

  # Safe defaults for laptops. Host-specific configs can override platform/profile.
  hardware.thermal = {
    enable = true;
    platform = lib.mkDefault "generic";
    profile = lib.mkDefault "balanced";
  };

  programs.nm-applet.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  programs.light.enable = true;

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
  };

  services.libinput.touchpad = {
    tapping = true;
    naturalScrolling = true;
    disableWhileTyping = true;
  };
}
