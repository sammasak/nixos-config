# Ironbar - Status Bar for Hyprland
# Note: Stylix doesn't auto-theme ironbar, colors are manual

{pkgs, ...}:
{
  home.packages = with pkgs; [
    ironbar
  ];

  xdg.configFile."ironbar/config.json".text = builtins.toJSON {
    position = "top";
    height = 32;

    start = [
      {
        type = "workspaces";
        all_monitors = false;
      }
    ];

    center = [
      {
        type = "focused";
        show_icon = true;
        show_title = true;
        icon_size = 24;
        truncate = {
          mode = "end";
          max_length = 50;
        };
      }
    ];

    end = [
      { type = "tray"; }
      {
        type = "volume";
        format = "{icon} {percentage}%";
        max_volume = 100;
      }
      {
        type = "network";
        format = {
          wifi = " {ssid}";
          ethernet = " Connected";
          disconnected = " Disconnected";
        };
      }
      {
        type = "battery";
        format = "{icon} {percentage}%";
      }
      {
        type = "clock";
        format = "%H:%M   %Y-%m-%d";
      }
    ];
  };

  # Minimal styling - matches dark theme
  xdg.configFile."ironbar/style.css".text = ''
    * {
      font-family: "JetBrains Mono", "Font Awesome 6 Free";
      font-size: 12px;
    }

    #bar {
      background-color: rgba(26, 26, 26, 0.95);
      color: #ffffff;
    }

    #workspaces button {
      padding: 0 8px;
      background-color: transparent;
      color: #ffffff;
    }

    #workspaces button.focused {
      background-color: rgba(255, 255, 255, 0.2);
    }
  '';
}
