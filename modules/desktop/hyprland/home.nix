# Hyprland Desktop Environment
# Imports all hyprland-related programs and scripts
{ config, pkgs, lib, host, ... }:
let
  mkForce = lib.mkForce;
  vars = import ../../../hosts/${host}/variables.nix;
in
{
  imports = [
    ./programs/waybar/minimal.nix
    ./programs/rofi/default.nix
    ./programs/hyprlock/default.nix
    ./programs/hypridle/default.nix
    ./programs/swaync/default.nix
    ./programs/gtk/default.nix
    ./scripts
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;

    settings = {
      monitor = vars.monitors or [
        "preferred,auto,1"
      ];

      xwayland = {
        force_zero_scaling = true;
      };

      "$mod" = "SUPER";

      env = [
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "GDK_BACKEND,wayland,x11,*"
        "NIXOS_OZONE_WL,1"
        "ELECTRON_OZONE_PLATFORM_HINT,wayland"
        "MOZ_ENABLE_WAYLAND,1"
        "QT_QPA_PLATFORM,wayland;xcb"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
        "QT_AUTO_SCREEN_SCALE_FACTOR,1"
      ];

      master = {
        new_on_top = false;
        mfact = 0.5;
      };

      general = {
        gaps_in = 4;
        gaps_out = 9;
        border_size = 2;
        "col.active_border" = mkForce "rgba(ca9ee6ff) rgba(f2d5cfff) 45deg";
        "col.inactive_border" = mkForce "rgba(b4befecc) rgba(6c7086cc) 45deg";
        layout = "master";
        resize_on_border = true;
      };

      decoration = {
        rounding = 10;
        dim_special = 0.3;
        shadow = { enabled = false; };
        blur = {
          enabled = true;
          special = true;
          size = 6;
          passes = 2;
          xray = false;
        };
      };

      animations = {
        enabled = true;
        bezier = [
          "linear, 0, 0, 1, 1"
          "md3_standard, 0.2, 0, 0, 1"
          "md3_decel, 0.05, 0.7, 0.1, 1"
          "md3_accel, 0.3, 0, 0.8, 0.15"
          "overshot, 0.05, 0.9, 0.1, 1.1"
          "fluent_decel, 0.1, 1, 0, 1"
          "easeOutExpo, 0.16, 1, 0.3, 1"
        ];

        animation = [
          "windows, 1, 3, md3_decel, popin 60%"
          "windowsIn, 1, 3, md3_decel, popin 60%"
          "windowsOut, 1, 3, md3_accel, popin 60%"
          "border, 1, 10, default"
          "fade, 1, 2.5, md3_decel"
          "workspaces, 1, 3.5, easeOutExpo, slide"
          "specialWorkspace, 1, 3, md3_decel, slidevert"
        ];
      };

      input = {
        kb_layout = vars.kbdLayout or "se";
        follow_mouse = 1;
        sensitivity = 0;
        accel_profile = "flat";
        touchpad = {
          natural_scroll = true;
          disable_while_typing = true;
          tap-to-click = true;
        };
        repeat_rate = 50;
        repeat_delay = 240;
      };

      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        vrr = 0;
        animate_manual_resizes = true;
        animate_mouse_windowdragging = true;
      };

      exec-once = [
        "wallpaper-init"
        "wl-paste --type text --watch cliphist store"
        "wl-paste --type image --watch cliphist store"
        "nwg-dock-hyprland -d -i 16"
      ];

      bind = [
        # Application launchers
        "$mod, Return, exec, ${vars.terminal or "kitty"}"
        "$mod SHIFT, Return, exec, ${vars.terminal or "kitty"}"
        "$mod, D, exec, rofi -show drun"
        "$mod, A, exec, rofi -show drun"
        "$mod, Space, exec, rofi -show drun"
        "$mod, E, exec, thunar"
        "$mod, B, exec, ${vars.browser or "firefox"}"

        # Window management
        "$mod, Q, killactive,"
        "$mod SHIFT, Q, exit,"
        "$mod, F, fullscreen,"
        "$mod, W, togglefloating,"
        "$mod, C, centerwindow,"
        "$mod, Y, pin,"
        "$mod SHIFT, Space, swapnext,"

        # Focus movement (vim-style)
        "$mod, H, movefocus, l"
        "$mod, L, movefocus, r"
        "$mod, K, movefocus, u"
        "$mod, J, movefocus, d"

        # Window movement
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, L, movewindow, r"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, J, movewindow, d"

        # Window resizing
        "$mod CTRL, H, resizeactive, -50 0"
        "$mod CTRL, L, resizeactive, 50 0"
        "$mod CTRL, K, resizeactive, 0 -50"
        "$mod CTRL, J, resizeactive, 0 50"

        # Master layout
        "$mod, I, layoutmsg, addmaster"
        "$mod, O, layoutmsg, removemaster"
        "$mod CTRL, Return, layoutmsg, swapwithmaster"

        # Window grouping
        "$mod, G, togglegroup,"

        # Window cycling with visual selector (like macOS Command+Tab)
        "$mod, Tab, exec, rofi -show window"

        # Simple window cycling (current workspace only)
        "$mod CTRL, Tab, cyclenext,"
        "$mod CTRL, Tab, bringactivetotop,"
        "$mod CTRL SHIFT, Tab, cyclenext, prev"
        "$mod CTRL SHIFT, Tab, bringactivetotop,"

        # Minimize
        "$mod, N, movetoworkspacesilent, special:minimized"
        "$mod SHIFT, N, togglespecialworkspace, minimized"

        # Workspaces
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

        # Move to workspace
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

        # Move silent
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

        # Mouse scroll
        "$mod, mouse_down, workspace, e+1"
        "$mod, mouse_up, workspace, e-1"

        # Screenshots
        ", Print, exec, grim -g \"$(slurp)\" - | wl-copy"
        "SHIFT, Print, exec, grim - | wl-copy"
        "$mod SHIFT, S, exec, grim -g \"$(slurp)\" - | wl-copy"
        "$mod, P, exec, ~/.config/hypr/scripts/screenshot.sh s"
        "$mod SHIFT, P, exec, ~/.config/hypr/scripts/screenshot.sh sf"
        "$mod CTRL, P, exec, ~/.config/hypr/scripts/screenshot.sh m"

        # Screen recording
        "$mod SHIFT, R, exec, ~/.config/hypr/scripts/screen-record.sh a"
        "$mod CTRL, R, exec, ~/.config/hypr/scripts/screen-record.sh m"

        # Clipboard manager
        "$mod, V, exec, ~/.config/hypr/scripts/ClipManager.sh"

        # Wallpaper selector
        "$mod SHIFT, W, exec, ~/.config/hypr/scripts/wallpaper-select.sh"

        # Keybinds help
        "$mod, question, exec, ~/.config/hypr/scripts/keybinds.sh"

        # Notifications
        "$mod SHIFT, N, exec, swaync-client -t -sw"

        # Color picker
        "$mod SHIFT, C, exec, hyprpicker -a"

        # Lock screen
        "$mod, escape, exec, hyprlock"

        # Alt-Tab (simple focus cycling)
        "ALT, Tab, movefocus, d"
      ];

      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

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

      windowrulev2 = [
        "float,class:^(pavucontrol)$"
        "float,class:^(thunar)$,title:^(File Operation Progress)$"
        "float,class:^(yad)$"
        "float,title:^(Picture-in-Picture)$"
        "pin,title:^(Picture-in-Picture)$"
        "opacity 0.95 0.95,class:^(kitty)$"
      ];
    };
  };

  # Ensure swww is the only wallpaper daemon.
  services.hyprpaper.enable = lib.mkForce false;

  home.packages = [ pkgs.wdisplays ];
}
