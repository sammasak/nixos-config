# Enhanced Hyprland Configuration
# Based on best practices with master-stack layout, animations, and comprehensive keybindings

{config, pkgs, ...}:
{
  wayland.windowManager.hyprland = {
    enable = true;

    # Use system-provided Hyprland
    package = null;
    portalPackage = null;

    settings = {
      # Monitor configuration
      monitor = [
        ",preferred,auto,1"  # Auto-detect monitor, use preferred resolution, 1.25x scale
      ];

      xwayland = {
        force_zero_scaling = true;
      };

      # Modifier key
      "$mod" = "SUPER";

      # Master layout configuration
      master = {
        new_on_top = false;
        mfact = 0.5;
      };

      # General window settings
      general = {
        gaps_in = 0;
        gaps_out = 0;
        border_size = 1;
        layout = "master";
        resize_on_border = true;
        # Border colors managed by Stylix
      };

      # Decoration settings
      decoration = {
        rounding = 0;

        shadow = {
          enabled = true;
          range = 20;
          render_power = 2;
        };

        blur = {
          enabled = true;
          size = 5;
          passes = 2;
        };
      };

      # Animation settings
      animations = {
        enabled = true;
        bezier = [
          "wind, 0.05, 0.9, 0.1, 1.05"
          "winIn, 0.1, 1.1, 0.1, 1.1"
          "winOut, 0.3, -0.3, 0, 1"
          "liner, 1, 1, 1, 1"
        ];

        animation = [
          "windows, 1, 6, wind, slide"
          "windowsIn, 1, 6, winIn, slide"
          "windowsOut, 1, 5, winOut, slide"
          "windowsMove, 1, 5, wind, slide"
          "border, 1, 1, liner"
          "borderangle, 1, 30, liner, loop"
          "fade, 1, 10, default"
          "workspaces, 1, 5, wind"
        ];
      };

      # Input configuration
      input = {
        kb_layout = "se";
        follow_mouse = 1;
        sensitivity = 0;  # -1.0 to 1.0, 0 means no modification
        accel_profile = "flat";

        touchpad = {
          natural_scroll = true;
          disable_while_typing = true;
          tap-to-click = true;
        };

        # Keyboard repeat rate
        repeat_rate = 50;
        repeat_delay = 240;
      };

      # Misc settings
      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        vrr = 0;
      };

      # Autostart applications
      # Note: waybar, swaync, and hyprpaper are started via systemd services
      exec-once = [
        "nwg-dock-hyprland -d -i 16"
      ];

      # Key bindings
      bind = [
        # Application launchers
        "$mod, Return, exec, kitty"
        "$mod SHIFT, Return, exec, kitty"
        "$mod, D, exec, rofi -show drun"
        "$mod, E, exec, thunar"
        "$mod, B, exec, firefox"

        # Window management
        "$mod, Q, killactive,"
        "$mod SHIFT, Q, exit,"
        "$mod, F, fullscreen,"
        "$mod, Space, togglefloating,"
        "$mod, C, centerwindow,"
        "$mod, Y, pin,"
        "$mod SHIFT, Space, swapnext,"

        # Focus movement
        "$mod, H, movefocus, l"
        "$mod, L, movefocus, r"
        "$mod, K, movefocus, u"
        "$mod, J, movefocus, d"

        # Window movement
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, L, movewindow, r"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, J, movewindow, d"

        # Window resizing (keyboard)
        "$mod CTRL, H, resizeactive, -50 0"
        "$mod CTRL, L, resizeactive, 50 0"
        "$mod CTRL, K, resizeactive, 0 -50"
        "$mod CTRL, J, resizeactive, 0 50"

        # Master layout specific
        "$mod, I, layoutmsg, addmaster"
        "$mod, O, layoutmsg, removemaster"
        "$mod CTRL, Return, layoutmsg, swapwithmaster"

        # Window grouping (tabs)
        "$mod, G, togglegroup,"
        "$mod, Tab, changegroupactive, f"
        "$mod SHIFT, Tab, changegroupactive, b"

        # Minimize to special workspace
        "$mod, N, movetoworkspacesilent, special:minimized"
        "$mod SHIFT, N, togglespecialworkspace, minimized"

        # Workspace switching
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"

        # Move window to workspace
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        "$mod SHIFT, 6, movetoworkspace, 6"
        "$mod SHIFT, 7, movetoworkspace, 7"
        "$mod SHIFT, 8, movetoworkspace, 8"
        "$mod SHIFT, 9, movetoworkspace, 9"
        "$mod SHIFT, 0, movetoworkspace, 10"

        # Move window to workspace (silent - don't follow)
        "$mod CTRL, 1, movetoworkspacesilent, 1"
        "$mod CTRL, 2, movetoworkspacesilent, 2"
        "$mod CTRL, 3, movetoworkspacesilent, 3"
        "$mod CTRL, 4, movetoworkspacesilent, 4"
        "$mod CTRL, 5, movetoworkspacesilent, 5"
        "$mod CTRL, 6, movetoworkspacesilent, 6"
        "$mod CTRL, 7, movetoworkspacesilent, 7"
        "$mod CTRL, 8, movetoworkspacesilent, 8"
        "$mod CTRL, 9, movetoworkspacesilent, 9"
        "$mod CTRL, 0, movetoworkspacesilent, 10"

        # Scroll through workspaces
        "$mod, mouse_down, workspace, e+1"
        "$mod, mouse_up, workspace, e-1"

        # Screenshot
        ", Print, exec, grim -g \"$(slurp)\" - | wl-copy"
        "SHIFT, Print, exec, grim - | wl-copy"
        "$mod SHIFT, S, exec, grim -g \"$(slurp)\" - | wl-copy"

        # Notifications
        "$mod, W, exec, swaync-client -t -sw"

        # Color picker
        "$mod SHIFT, C, exec, hyprpicker -a"

        # Lock screen
        "$mod, escape, exec, hyprlock"

        # Alt-Tab for window switching (custom script with rofi)
        "ALT, TAB, exec, hyprland-window-switcher"
      ];

      # Mouse bindings
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

      # Media keys
      bindl = [
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioPrev, exec, playerctl previous"
        ", XF86AudioNext, exec, playerctl next"
      ];

      bindle = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
      ];

      # Window rules
      windowrulev2 = [
        "float,class:^(pavucontrol)$"
        "float,class:^(thunar)$,title:^(File Operation Progress)$"
        "opacity 0.95 0.95,class:^(kitty)$"
      ];
    };
  };
}
