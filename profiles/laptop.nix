# Laptop profile - Power management and mobile-specific features
# Use this for portable machines

{pkgs, ...}:
{
  # Power management
  services.power-profiles-daemon.enable = true;

  # Lid switch handling
  services.logind = {
    settings = {
      Login = {
        HandleLidSwitch = "suspend";
        HandleLidSwitchExternalPower = "suspend";
      };
    };
  };

  # Touchpad support
  services.libinput.enable = true;
  services.libinput.touchpad = {
    tapping = true;
    naturalScrolling = true;
    disableWhileTyping = true;
  };

  # Backlight control
  programs.light.enable = true;

  # Battery monitoring
  services.upower.enable = true;
}
