# Waybar - Status Bar for Hyprland
# Based on mylinuxforwork/dotfiles ml4w-glass theme

{pkgs, ...}:
{
  home.packages = with pkgs; [
    waybar
  ];

  # Waybar configuration
  xdg.configFile."waybar/config".text = builtins.toJSON {
    layer = "top";
    position = "top";
    height = 8;
    margin-top = 0;
    margin-bottom = 0;
    margin-left = 0;
    margin-right = 0;
    spacing = 0;

    modules-left = [
      "custom/appmenu"
      "hyprland/workspaces"
    ];

    modules-center = [
      "clock"
    ];

    modules-right = [
      "pulseaudio"
      "network"
      "battery"
      "tray"
    ];

    "hyprland/workspaces" = {
      on-scroll-up = "hyprctl dispatch workspace r-1";
      on-scroll-down = "hyprctl dispatch workspace r+1";
      on-click = "activate";
      active-only = false;
      all-outputs = true;
      format = "{}";
      format-icons = {
        urgent = "";
        active = "";
        default = "";
      };
      persistent-workspaces = {
        "*" = 5;
      };
    };

    clock = {
      format = "{:%H:%M %a}";
      tooltip = false;
    };

    pulseaudio = {
      format = "{icon} {volume}%";
      format-muted = "";
      format-icons = {
        default = ["" ""];
      };
      on-click = "pavucontrol";
    };

    network = {
      format-wifi = " {signalStrength}%";
      format-ethernet = " {ifname}";
      format-disconnected = "Disconnected ⚠";
      tooltip-format-wifi = " {ifname} @ {essid}\nStrength: {signalStrength}%";
      tooltip-format-ethernet = " {ifname}";
      tooltip-format-disconnected = "Disconnected";
      max-length = 50;
    };

    battery = {
      interval = 1;
      states = {
        warning = 30;
        critical = 15;
      };
      format = "{icon} {capacity}%";
      format-charging = " {capacity}%";
      format-plugged = " {capacity}%";
      format-icons = ["" "" "" "" ""];
    };

    tray = {
      icon-size = 16;
      spacing = 10;
    };

    "custom/appmenu" = {
      format = "Apps";
      on-click = "rofi -show drun";
      tooltip-format = "Open application launcher";
    };
  };

  xdg.configFile."waybar/style.css".text = ''
    * {
      font-family: "JetBrains Mono", "Font Awesome 6 Free", Roboto, sans-serif;
      font-size: 10px;
      border: none;
      border-radius: 0px;
    }

    window#waybar {
      background: transparent;
    }

    .modules-left {
      background-color: rgba(0, 0, 0, 0.8);
      border-radius: 12px;
      opacity: 0.8;
      padding: 0px;
      margin: 2px;
    }

    .modules-right {
      background-color: rgba(0, 0, 0, 0.8);
      border-radius: 12px;
      opacity: 0.8;
      padding: 0px;
      margin: 2px;
    }

    .modules-center {
      background-color: rgba(0, 0, 0, 0.8);
      border-radius: 12px;
      opacity: 0.8;
      margin: 2px;
    }

    #workspaces {
      padding: 1px 1px 1px 1px;
      min-width: 140px;
    }

    #workspaces button {
      color: #ffffff;
      border-radius: 3px;
      padding: 0px 3px 0px 3px;
      margin: 0px 1px 0px 1px;
      transition: all 0.3s ease-in-out;
      border: 1px solid transparent;
    }

    #workspaces button.active {
      background: rgba(255, 255, 255, 0.1);
      min-width: 20px;
      border-radius: 4px;
    }

    #workspaces button:hover {
      background: rgba(255, 255, 255, 0.1);
      border-radius: 15px;
    }

    #clock {
      margin-left: 8px;
      margin-right: 8px;
    }

    #pulseaudio, #network, #battery {
      margin: 0px 5px;
    }

    #tray {
      padding: 0px 5px 0px 10px;
    }

    #tray > .passive {
      -gtk-icon-effect: dim;
    }

    #tray > .needs-attention {
      -gtk-icon-effect: highlight;
    }
  '';
}