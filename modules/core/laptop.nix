# Laptop-specific configuration
{ ... }:
{
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
