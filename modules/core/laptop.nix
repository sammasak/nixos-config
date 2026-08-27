{ config, lib, ... }:
let
  hasDesktop = config.sam.desktop.enable;
in
{
  imports = [
    ../hardware/thermal.nix
  ];

  # Safe defaults for laptops. Host-specific configs can override platform/profile.
  sam.thermal = {
    enable = true;
    platform = lib.mkDefault "generic";
    profile = lib.mkDefault "balanced";
  };

  # Desktop-only: a tray applet needs a tray, and acpilight's backlight udev
  # rules only matter to an interactive session. upower and
  # power-profiles-daemon stay ungated — both are headless-useful (battery
  # state, thermal/power policy).
  programs.nm-applet.enable = hasDesktop;
  hardware.acpilight.enable = hasDesktop;

  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

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
