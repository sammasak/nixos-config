{ pkgs, ... }:
let
  # The stock hypridle recipe (`hyprctl dispatch dpms`) does nothing under niri, so DPMS goes
  # through niri's own action. No idle logout: niri quit would close every app, defeating resume.
  dpms = pkgs.writeShellScript "hypridle-dpms" ''
    case "$1" in
      off) niri="power-off-monitors" ;;
      on)  niri="power-on-monitors" ;;
      *) exit 2 ;;
    esac
    if [ -n "''${NIRI_SOCKET:-}" ]; then
      exec niri msg action "$niri"
    fi
  '';
in
{
  services.hypridle = {
    enable = true;

    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "${dpms} on";
      };

      listener = [
        {
          timeout = 300;
          on-timeout = "brightnessctl -s set 10%";
          on-resume = "brightnessctl -r";
        }
        {
          timeout = 300;
          on-timeout = "brightnessctl -sd tpacpi::kbd_backlight set 0";
          on-resume = "brightnessctl -rd tpacpi::kbd_backlight";
        }
        {
          timeout = 600;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 760;
          on-timeout = "${dpms} off";
          on-resume = "${dpms} on";
        }
      ];
    };
  };
}
