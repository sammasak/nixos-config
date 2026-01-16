# Waybar - Status Bar for Hyprland
# Minimal theme with Catppuccin Mocha colors
{ pkgs, ... }:
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        mode = "dock";
        height = 32;
        exclusive = true;
        passthrough = false;
        gtk-layer-shell = true;
        fixed-center = true;
        ipc = true;
        margin-top = 10;
        margin-left = 10;
        margin-right = 10;
        margin-bottom = 0;

        modules-left = [
          "hyprland/workspaces"
          "cpu"
          "temperature"
          "memory"
        ];

        modules-center = [
          "idle_inhibitor"
          "clock"
          "custom/notification"
        ];

        modules-right = [
          "backlight"
          "pulseaudio"
          "network"
          "bluetooth"
          "tray"
          "battery"
        ];

        "idle_inhibitor" = {
          format = "{icon}";
          format-icons = {
            activated = "󰥔";
            deactivated = "";
          };
        };

        backlight = {
          interval = 2;
          format = "{icon} {percent}%";
          format-icons = [ "" "" "" "" "" "" "" "" "" ];
          on-scroll-up = "brightnessctl set +5%";
          on-scroll-down = "brightnessctl set 5%-";
        };

        battery = {
          interval = 60;
          full-at = 100;
          states = {
            good = 95;
            warning = 30;
            critical = 20;
          };
          format = "{icon} {capacity}%";
          format-charging = " {capacity}%";
          format-plugged = " {capacity}%";
          format-full = "{icon} Full";
          format-alt = "{time} {icon}";
          format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
          format-time = "{H}h {M}min";
          tooltip = true;
          tooltip-format = "{timeTo} {power}w";
        };

        bluetooth = {
          format = "";
          format-connected = " {num_connections}";
          tooltip-format = " {device_alias}";
          tooltip-format-connected = "{device_enumerate}";
          tooltip-format-enumerate-connected = " {device_alias}";
          on-click = "blueman-manager";
        };

        clock = {
          format = "{:%a %d %b %H:%M}";
          format-alt = "{:%I:%M %p}";
          tooltip-format = "<tt>{calendar}</tt>";
          calendar = {
            mode = "month";
            mode-mon-col = 3;
            on-scroll = 1;
            on-click-right = "mode";
            format = {
              months = "<span color='#ffead3'><b>{}</b></span>";
              weekdays = "<span color='#ffcc66'><b>{}</b></span>";
              today = "<span color='#ff6699'><b>{}</b></span>";
            };
          };
          actions = {
            on-click-right = "mode";
            on-scroll-up = "shift_up";
            on-scroll-down = "shift_down";
          };
        };

        cpu = {
          format = "󰍛 {usage}%";
          interval = 10;
          format-alt = "{icon0}{icon1}{icon2}{icon3}";
          format-icons = [ "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" ];
        };

        "hyprland/language" = {
          format = "{short}";
        };

        "hyprland/workspaces" = {
          disable-scroll = true;
          all-outputs = true;
          active-only = false;
          on-click = "activate";
          persistent-workspaces = {
            "*" = [ 1 2 3 4 5 ];
          };
        };

        memory = {
          interval = 30;
          format = "󰾆 {percentage}%";
          format-alt = "󰾅 {used}GB";
          max-length = 10;
          tooltip = true;
          tooltip-format = " {used:.1f}GB/{total:.1f}GB";
          on-click-right = "kitty --title btop sh -c 'btop'";
        };

        network = {
          format-wifi = "󰤨 Wi-Fi";
          format-ethernet = "󱘖 Wired";
          format-linked = "󰤪 Linked";
          format-disconnected = "󰤮 Off";
          format-alt = "󰤨 {signalStrength}%";
          tooltip-format = "󱘖 {ipaddr}  {bandwidthUpBytes}  {bandwidthDownBytes}";
        };

        pulseaudio = {
          format = "{icon} {volume}%";
          format-muted = " ";
          on-click = "pavucontrol -t 3";
          tooltip-format = "{icon} {desc} // {volume}%";
          scroll-step = 5;
          format-icons = {
            headphone = "";
            hands-free = "";
            headset = "";
            phone = "";
            portable = "";
            car = "";
            default = [ "" "" "" ];
          };
        };

        "pulseaudio#microphone" = {
          format = "{format_source}";
          format-source = " {volume}%";
          format-source-muted = "";
          on-click = "pavucontrol -t 4";
          tooltip-format = "{format_source} {source_desc} // {source_volume}%";
          scroll-step = 5;
        };

        temperature = {
          interval = 10;
          tooltip = false;
          critical-threshold = 82;
          format-critical = "{icon} {temperatureC}°C";
          format = "󰈸 {temperatureC}°C";
        };

        tray = {
          icon-size = 12;
          spacing = 5;
        };

        "custom/notification" = {
          tooltip = false;
          format = "{icon}";
          format-icons = {
            notification = "<span foreground='#f38ba8'><sup></sup></span>";
            none = "";
            dnd-notification = "<span foreground='#f38ba8'><sup></sup></span>";
            dnd-none = "";
            inhibited-notification = "<span foreground='#f38ba8'><sup></sup></span>";
            inhibited-none = "";
            dnd-inhibited-notification = "<span foreground='#f38ba8'><sup></sup></span>";
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
        font-family: "JetBrainsMono Nerd Font";
        font-size: 12px;
        margin: 0px;
        padding: 0px;
      }

      /* Catppuccin Mocha Colors */
      @define-color base   #1e1e2e;
      @define-color mantle #181825;
      @define-color crust  #11111b;

      @define-color text     #cdd6f4;
      @define-color subtext0 #a6adc8;
      @define-color subtext1 #bac2de;

      @define-color surface0 #313244;
      @define-color surface1 #45475a;
      @define-color surface2 #585b70;

      @define-color overlay0 #6c7086;
      @define-color overlay1 #7f849c;
      @define-color overlay2 #9399b2;

      @define-color blue      #89b4fa;
      @define-color lavender  #b4befe;
      @define-color sapphire  #74c7ec;
      @define-color sky       #89dceb;
      @define-color teal      #94e2d5;
      @define-color green     #a6e3a1;
      @define-color yellow    #f9e2af;
      @define-color peach     #fab387;
      @define-color maroon    #eba0ac;
      @define-color red       #f38ba8;
      @define-color mauve     #cba6f7;
      @define-color pink      #f5c2e7;
      @define-color flamingo  #f2cdcd;
      @define-color rosewater #f5e0dc;

      window#waybar {
        transition-property: background-color;
        transition-duration: 0.5s;
        background: transparent;
        border-radius: 10px;
      }

      window#waybar.hidden {
        opacity: 0.2;
      }

      tooltip {
        background: @base;
        border-radius: 8px;
      }

      tooltip label {
        color: @text;
        margin: 5px;
      }

      .modules-left {
        background: alpha(@base, 0.85);
        border: 1px solid @blue;
        padding-right: 15px;
        padding-left: 2px;
        border-radius: 10px;
      }

      .modules-center {
        background: alpha(@base, 0.85);
        border: 0.5px solid @overlay0;
        padding-right: 5px;
        padding-left: 5px;
        border-radius: 10px;
      }

      .modules-right {
        background: alpha(@base, 0.85);
        border: 1px solid @blue;
        padding-right: 15px;
        padding-left: 15px;
        border-radius: 10px;
      }

      #backlight,
      #backlight-slider,
      #battery,
      #bluetooth,
      #clock,
      #cpu,
      #idle_inhibitor,
      #memory,
      #network,
      #pulseaudio,
      #temperature,
      #tray,
      #workspaces,
      #custom-notification {
        padding-top: 3px;
        padding-bottom: 3px;
        padding-right: 5px;
        padding-left: 5px;
      }

      #idle_inhibitor {
        color: @blue;
      }

      #bluetooth,
      #backlight {
        color: @blue;
      }

      #battery {
        color: @green;
      }

      @keyframes blink {
        to {
          color: @surface0;
        }
      }

      #battery.critical:not(.charging) {
        background-color: @red;
        color: @base;
        animation-name: blink;
        animation-duration: 0.5s;
        animation-timing-function: linear;
        animation-iteration-count: infinite;
        animation-direction: alternate;
      }

      #clock {
        color: @yellow;
      }

      #cpu {
        color: @yellow;
      }

      #memory {
        color: @green;
      }

      #temperature {
        color: @teal;
      }

      #temperature.critical {
        background-color: @red;
        color: @base;
      }

      #network {
        color: @blue;
      }

      #network.disconnected,
      #network.disabled {
        background-color: @surface0;
        color: @text;
      }

      #pulseaudio {
        color: @lavender;
      }

      #pulseaudio.muted {
        color: @red;
      }

      #tray > .passive {
        -gtk-icon-effect: dim;
      }

      #tray > .needs-attention {
        -gtk-icon-effect: highlight;
      }

      #workspaces button {
        box-shadow: none;
        text-shadow: none;
        padding: 0px;
        border-radius: 9px;
        padding-left: 4px;
        padding-right: 4px;
        color: @surface1;
        transition: all 0.5s cubic-bezier(.55,-0.68,.48,1.682);
      }

      #workspaces button:hover {
        border-radius: 10px;
        color: @overlay0;
        background-color: @surface0;
        padding-left: 2px;
        padding-right: 2px;
        transition: all 0.3s cubic-bezier(.55,-0.68,.48,1.682);
      }

      #workspaces button.persistent {
        color: @surface1;
        border-radius: 10px;
      }

      #workspaces button.active {
        color: @peach;
        border-radius: 10px;
        padding-left: 8px;
        padding-right: 8px;
        transition: all 0.3s cubic-bezier(.55,-0.68,.48,1.682);
      }

      #workspaces button.urgent {
        color: @red;
        border-radius: 0px;
      }

      #custom-notification {
        color: @text;
        padding: 0px 5px;
        border-radius: 5px;
      }
    '';
  };

  home.packages = with pkgs; [
    pamixer
    blueman
    btop
  ];
}
