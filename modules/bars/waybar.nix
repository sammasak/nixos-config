# Waybar - Status Bar for Hyprland
# Uses Stylix colors for consistent theming

{ pkgs, config, ... }:
let
  theme = import ../../lib/theme.nix;
  colors = config.lib.stylix.colors.withHashtag;
in
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        exclusive = true;
        passthrough = false;
        fixed-center = true;
        ipc = true;
        margin-top = 2;
        margin-left = 2;
        margin-right = 2;
        height = 24;

        modules-left = [
          "hyprland/workspaces"
          "cpu"
          "temperature"
          "memory"
          "backlight"
        ];

        modules-center = [
          "clock"
          "custom/notification"
        ];

        modules-right = [
          "privacy"
          "hyprland/language"
          "tray"
          "bluetooth"
          "pulseaudio"
          "pulseaudio#microphone"
          "battery"
        ];

        backlight = {
          interval = 2;
          align = 0;
          rotate = 0;
          format = "{icon} {percent}%";
          format-icons = [ "󰃞" "󰃟" "󰃝" "󰃠" ];
          icon-size = 10;
          on-scroll-up = "brightnessctl set +5%";
          on-scroll-down = "brightnessctl set 5%-";
          smooth-scrolling-threshold = 1;
        };

        battery = {
          interval = 60;
          align = 0;
          rotate = 0;
          full-at = 100;
          design-capacity = false;
          states = {
            good = 95;
            warning = 30;
            critical = 20;
          };
          format = "<big>{icon}</big>  {capacity}%";
          format-charging = " {capacity}%";
          format-plugged = " {capacity}%";
          format-full = "{icon} Full";
          format-alt = "{icon} {time}";
          format-icons = [ "" "" "" "" "" ];
          format-time = "{H}h {M}min";
          tooltip = true;
          tooltip-format = "{timeTo} {power}w";
        };

        bluetooth = {
          format = "";
          format-connected = " {num_connections}";
          tooltip-format = " {device_alias}";
          tooltip-format-connected = "{device_enumerate}";
          tooltip-format-enumerate-connected = "Name: {device_alias}\nBattery: {device_battery_percentage}%";
          on-click = "blueman-manager";
        };

        clock = {
          format = "{:%b %d %H:%M}";
          format-alt = " {:%H:%M   %Y, %d %B, %A}";
          tooltip-format = "<tt><small>{calendar}</small></tt>";
          calendar = {
            mode = "year";
            mode-mon-col = 3;
            weeks-pos = "right";
            on-scroll = 1;
            format = {
              months = "<span color='${colors.base09}'><b>{}</b></span>";
              days = "<span color='${colors.base05}'><b>{}</b></span>";
              weeks = "<span color='${colors.base04}'><b>W{}</b></span>";
              weekdays = "<span color='${colors.base0D}'><b>{}</b></span>";
              today = "<span color='${colors.base08}'><b><u>{}</u></b></span>";
            };
          };
        };

        cpu = {
          format = "󰍛 {usage}%";
          interval = 1;
        };

        "hyprland/language" = {
          format = "{short}";
        };

        "hyprland/workspaces" = {
          all-outputs = true;
          format = "{name}";
          on-click = "activate";
          show-special = false;
          sort-by-number = true;
        };

        memory = {
          interval = 10;
          format = "󰾆 {used:0.1f}G";
          format-alt = "󰾆 {percentage}%";
          format-alt-click = "click";
          tooltip = true;
          tooltip-format = "{used:0.1f}GB/{total:0.1f}G";
          on-click-right = "kitty --title btop sh -c 'btop'";
        };

        privacy = {
          icon-size = 14;
          modules = [
            {
              type = "screenshare";
              tooltip = true;
            }
          ];
        };

        pulseaudio = {
          format = "{icon} {volume}%";
          format-muted = "";
          format-icons = {
            default = [ "" "" " " ];
          };
          on-click = "pavucontrol";
          on-scroll-up = "pamixer -i 5";
          on-scroll-down = "pamixer -d 5";
          scroll-step = 5;
          on-click-right = "pamixer -t";
          smooth-scrolling-threshold = 1;
        };

        "pulseaudio#microphone" = {
          format = "{format_source}";
          format-source = " {volume}%";
          format-source-muted = "";
          on-click = "pavucontrol";
          on-click-right = "pamixer --default-source -t";
          on-scroll-up = "pamixer --default-source -i 5";
          on-scroll-down = "pamixer --default-source -d 5";
        };

        temperature = {
          interval = 10;
          tooltip = false;
          critical-threshold = 82;
          format-critical = "{icon} {temperatureC}°C";
          format = "󰈸 {temperatureC}°C";
        };

        tray = {
          spacing = 20;
        };

        "custom/notification" = {
          tooltip = false;
          format = "{icon}";
          format-icons = {
            notification = "<span foreground='${colors.base08}'><sup></sup></span>";
            none = "";
            dnd-notification = "<span foreground='${colors.base08}'><sup></sup></span>";
            dnd-none = "";
            inhibited-notification = "<span foreground='${colors.base08}'><sup></sup></span>";
            inhibited-none = "";
            dnd-inhibited-notification = "<span foreground='${colors.base08}'><sup></sup></span>";
            dnd-inhibited-none = "";
          };
          return-type = "json";
          exec-if = "which swaync-client";
          exec = "swaync-client -swb";
          on-click = "swaync-client -t -sw";
          on-click-right = "swaync-client -d -sw";
          escape = true;
        };
      };
    };

    style = ''
      * {
        font-family: "${theme.fonts.monoNerd}";
        font-weight: bold;
        min-height: 0;
        font-size: 11px;
        font-feature-settings: '"zero", "ss01", "ss02", "ss03", "ss04", "ss05", "cv31"';
        padding: 0px;
        margin: 0px;
      }

      window#waybar {
        background: rgba(0, 0, 0, 0);
      }

      window#waybar.hidden {
        opacity: 0.5;
      }

      tooltip {
        background: ${colors.base00};
        border-radius: 6px;
        font-size: 11px;
      }

      tooltip label {
        color: ${colors.base05};
        margin: 2px 4px;
      }

      .modules-right,
      .modules-center,
      .modules-left {
        background-color: alpha(${colors.base00}, 0.7);
        border: 0px solid ${colors.base0D};
        border-radius: 6px;
        padding: 0px 2px;
      }

      #workspaces button {
        padding: 0px 4px;
        color: ${colors.base04};
        margin-right: 2px;
      }

      #workspaces button.active {
        color: ${colors.base05};
        border-radius: 3px;
      }

      #workspaces button.focused {
        color: ${colors.base05};
      }

      #workspaces button.urgent {
        color: ${colors.base08};
        border-radius: 6px;
      }

      #workspaces button:hover {
        color: ${colors.base05};
        border-radius: 3px;
      }

      #backlight,
      #battery,
      #bluetooth,
      #clock,
      #cpu,
      #custom-notification,
      #language,
      #memory,
      #privacy,
      #pulseaudio,
      #temperature,
      #tray,
      #workspaces {
        color: ${colors.base05};
        padding: 0px 6px;
        border-radius: 6px;
      }

      #temperature.critical {
        background-color: ${colors.base08};
      }

      @keyframes blink {
        to {
          color: ${colors.base00};
        }
      }

      #taskbar button.active {
        background-color: ${colors.base04};
      }

      #battery.critical:not(.charging) {
        color: ${colors.base08};
        animation-name: blink;
        animation-duration: 0.5s;
        animation-timing-function: linear;
        animation-iteration-count: infinite;
        animation-direction: alternate;
      }

      #privacy {
        color: ${colors.base09};
      }
    '';
  };

  home.packages = with pkgs; [
    pamixer
    blueman
    btop
  ];
}
