# Hypridle - Idle Management for Hyprland
# Automatically dims, locks, and powers off display when idle

{pkgs, ...}:
{
  services.hypridle = {
    enable = true;

    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "hyprctl dispatch dpms on";
      };

      listener = [
        {
          # Dim display after 2.5 minutes
          timeout = 150;
          on-timeout = "brightnessctl -s set 10%";
          on-resume = "brightnessctl -r";
        }
        {
          # Dim keyboard backlight after 2.5 minutes
          timeout = 150;
          on-timeout = "brightnessctl -sd tpacpi::kbd_backlight set 0";
          on-resume = "brightnessctl -rd tpacpi::kbd_backlight";
        }
        {
          # Lock session after 5 minutes
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          # Turn off display after 6.3 minutes
          timeout = 380;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
      ];
    };
  };
}
