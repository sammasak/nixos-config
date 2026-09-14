{ pkgs, ... }:
let
  # hypridle is WantedBy=graphical-session.target, so it runs under niri too, not
  # just Hyprland, where bare `hyprctl dispatch dpms` is a silent no-op. This
  # dispatches DPMS per live compositor. No idle logout: niri quit/hyprctl exit
  # would close every app, defeating resume. See vault:
  # desktop-niri-hyprland-lua-herdr.md
  dpms = pkgs.writeShellScript "hypridle-dpms" ''
    case "$1" in
      off) hypr="dpms off"; niri="power-off-monitors" ;;
      on)  hypr="dpms on";  niri="power-on-monitors" ;;
      *) exit 2 ;;
    esac
    if [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      exec hyprctl dispatch $hypr
    elif [ -n "''${NIRI_SOCKET:-}" ]; then
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
