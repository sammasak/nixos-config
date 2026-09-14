{ config, pkgs, lib, osConfig ? null, ... }:
let
  inherit (lib) mkForce;
  inherit (lib.generators) mkLuaInline;
  baseProfile =
    if osConfig != null && osConfig ? sam && osConfig.sam ? profile
    then osConfig.sam.profile
    else { };
  # terminal/browser are unconditional overrides, not defaults: they were
  # dropped from sam.profile and nothing else supplies them.
  profile = baseProfile // {
    monitors = baseProfile.monitors or [ ",preferred,auto,1" ];
    kbdLayout = baseProfile.kbdLayout or "se";
    terminal = "ghostty";
    browser = "firefox";
  };

  # Lua config helpers: b/bf build hl.bind() `_args` (key, dispatcher, flags?);
  # env/curve build the matching env{}/curve{} entries. Keys stay plain Nix
  # strings so HM's toLua does the escaping; only dispatchers are raw Lua.
  b = k: d: { _args = [ k (mkLuaInline d) ]; };
  bf = k: d: f: { _args = [ k (mkLuaInline d) f ]; };
  env = n: v: { _args = [ n v ]; };
  curve = n: x1: y1: x2: y2: { _args = [ n { type = "bezier"; points = [ [ x1 y1 ] [ x2 y2 ] ]; } ]; };

  # monitor = "name,res,pos,scale" (hyprlang) -> hl.monitor{ output,mode,position,scale }.
  parseMonitor =
    s:
    let
      p = lib.splitString "," s;
      at = i: lib.elemAt p i;
      scaleStr = at 3;
    in
    if builtins.length p != 4 then
      throw "sam.profile.monitors: expected 4 comma-separated fields (name,resolution,position,scale) in '${s}'"
    else
    {
      output = at 0;
      mode = at 1;
      position = at 2;
      scale = if scaleStr == "auto" then "auto" else builtins.fromJSON scaleStr;
    };

  wsRange = builtins.genList (i: i + 1) 10;
  wsKey = n: if n == 10 then "0" else toString n;
  wsFocus = map (n: b "SUPER + ${wsKey n}" "hl.dsp.focus({ workspace = ${toString n} })") wsRange;
  wsMove = map (n: b "SUPER + SHIFT + ${wsKey n}" "hl.dsp.window.move({ workspace = ${toString n} })") wsRange;
  wsMoveSilent = map (n: b "SUPER + CTRL + ${wsKey n}" "hl.dsp.window.move({ workspace = ${toString n}, follow = false })") wsRange;
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
    configType = "lua";

    # In extraCommands (not the settings.on hook) so they run after HM's dbus
    # environment import — a user unit started before it can miss WAYLAND_DISPLAY.
    # waybar restart + polkit start are belt-and-braces for post-SDDM relogin,
    # where the session target was never re-reached.
    systemd.extraCommands = [
      "systemctl --user stop hyprland-session.target"
      "systemctl --user start hyprland-session.target"
      "systemctl --user restart waybar.service"
      "systemctl --user start hyprpolkitagent.service"
    ];

    settings = {
      monitor = map parseMonitor profile.monitors;

      env = [
        (env "XDG_CURRENT_DESKTOP" "Hyprland")
        (env "XDG_SESSION_DESKTOP" "Hyprland")
        (env "XDG_SESSION_TYPE" "wayland")
        (env "GDK_BACKEND" "wayland,x11,*")
        (env "NIXOS_OZONE_WL" "1")
        (env "ELECTRON_OZONE_PLATFORM_HINT" "wayland")
        (env "MOZ_ENABLE_WAYLAND" "1")
        (env "QT_QPA_PLATFORM" "wayland;xcb")
        (env "QT_WAYLAND_DISABLE_WINDOWDECORATION" "1")
        (env "QT_AUTO_SCREEN_SCALE_FACTOR" "1")
      ];

      config = {
        general = {
          gaps_in = 4;
          gaps_out = 9;
          border_size = 2;
          # Dotted keys match Stylix's Lua colour form so mkForce overrides it.
          # Gradient tables, not hyprlang "rgba(..) rgba(..) 45deg" strings: the
          # Lua layer rejects those as invalid colors at config load.
          "col.active_border" = mkForce { colors = [ "rgba(ca9ee6ff)" "rgba(f2d5cfff)" ]; angle = 45; };
          "col.inactive_border" = mkForce { colors = [ "rgba(b4befecc)" "rgba(6c7086cc)" ]; angle = 45; };
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

        animations = { enabled = true; };

        input = {
          kb_layout = profile.kbdLayout;
          follow_mouse = 1;
          sensitivity = 0;
          accel_profile = "flat";
          touchpad = {
            natural_scroll = true;
            disable_while_typing = true;
            tap_to_click = true;
          };
          repeat_rate = 50;
          repeat_delay = 240;
        };

        master = {
          new_on_top = false;
          mfact = 0.5;
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

        xwayland = { force_zero_scaling = true; };
      };

      curve = [
        (curve "linear" 0 0 1 1)
        (curve "md3_standard" 0.2 0 0 1)
        (curve "md3_decel" 0.05 0.7 0.1 1)
        (curve "md3_accel" 0.3 0 0.8 0.15)
        (curve "overshot" 0.05 0.9 0.1 1.1)
        (curve "fluent_decel" 0.1 1 0 1)
        (curve "easeOutExpo" 0.16 1 0.3 1)
      ];

      animation = [
        { leaf = "windows"; enabled = true; speed = 3; bezier = "md3_decel"; style = "popin 60%"; }
        { leaf = "windowsIn"; enabled = true; speed = 3; bezier = "md3_decel"; style = "popin 60%"; }
        { leaf = "windowsOut"; enabled = true; speed = 3; bezier = "md3_accel"; style = "popin 60%"; }
        { leaf = "border"; enabled = true; speed = 10; bezier = "default"; }
        { leaf = "fade"; enabled = true; speed = 2.5; bezier = "md3_decel"; }
        { leaf = "workspaces"; enabled = true; speed = 3.5; bezier = "easeOutExpo"; style = "slide"; }
        { leaf = "specialWorkspace"; enabled = true; speed = 3; bezier = "md3_decel"; style = "slidevert"; }
      ];

      gesture = {
        fingers = 3;
        direction = "horizontal";
        action = "workspace";
      };

      on = {
        _args = [
          "hyprland.start"
          (mkLuaInline ''
            function()
              hl.exec_cmd("wallpaper-init")
              hl.exec_cmd("wl-paste --type text --watch cliphist store")
              hl.exec_cmd("wl-paste --type image --watch cliphist store")
            end
          '')
        ];
      };

      bind = [
        # Application launchers
        (b "SUPER + Return" ''hl.dsp.exec_cmd("${profile.terminal}")'')
        (b "SUPER + SHIFT + Return" ''hl.dsp.exec_cmd("${profile.terminal}")'')
        (b "SUPER + D" ''hl.dsp.exec_cmd("rofi -show drun")'')
        (b "SUPER + A" ''hl.dsp.exec_cmd("rofi -show drun")'')
        (b "SUPER + Space" ''hl.dsp.exec_cmd("rofi -show drun")'')
        (b "SUPER + E" ''hl.dsp.exec_cmd("ghostty -e yazi")'')
        (b "SUPER + B" ''hl.dsp.exec_cmd("${profile.browser}")'')

        # Window management
        (b "SUPER + Q" ''hl.dsp.window.close()'')
        (b "SUPER + SHIFT + Q" ''hl.dsp.exit()'')
        (b "SUPER + F" ''hl.dsp.window.fullscreen()'')
        (b "SUPER + W" ''hl.dsp.window.float({ action = "toggle" })'')
        (b "SUPER + C" ''hl.dsp.window.center()'')
        (b "SUPER + Y" ''hl.dsp.window.pin()'')
        # hyprctl dispatch: swapnext's and cyclenext-prev's Lua arg shapes are
        # unverified for 0.56, and a bad Lua arg aborts config load; the shell
        # dispatcher is stable.
        (b "SUPER + SHIFT + Space" ''hl.dsp.exec_cmd("hyprctl dispatch swapnext")'')

        # Focus movement (vim-style)
        (b "SUPER + H" ''hl.dsp.focus({ direction = "left" })'')
        (b "SUPER + L" ''hl.dsp.focus({ direction = "right" })'')
        (b "SUPER + K" ''hl.dsp.focus({ direction = "up" })'')
        (b "SUPER + J" ''hl.dsp.focus({ direction = "down" })'')

        # Window movement
        (b "SUPER + SHIFT + H" ''hl.dsp.window.move({ direction = "left" })'')
        (b "SUPER + SHIFT + L" ''hl.dsp.window.move({ direction = "right" })'')
        (b "SUPER + SHIFT + K" ''hl.dsp.window.move({ direction = "up" })'')
        (b "SUPER + SHIFT + J" ''hl.dsp.window.move({ direction = "down" })'')

        # Window resizing
        (b "SUPER + CTRL + H" ''hl.dsp.window.resize({ x = -50, y = 0, relative = true })'')
        (b "SUPER + CTRL + L" ''hl.dsp.window.resize({ x = 50, y = 0, relative = true })'')
        (b "SUPER + CTRL + K" ''hl.dsp.window.resize({ x = 0, y = -50, relative = true })'')
        (b "SUPER + CTRL + J" ''hl.dsp.window.resize({ x = 0, y = 50, relative = true })'')

        # Master layout
        (b "SUPER + I" ''hl.dsp.layout("addmaster")'')
        (b "SUPER + O" ''hl.dsp.layout("removemaster")'')
        (b "SUPER + CTRL + Return" ''hl.dsp.layout("swapwithmaster")'')

        (b "SUPER + G" ''hl.dsp.group.toggle()'')

        # Window cycling: Tab opens a visual selector, CTRL+Tab is direct.
        (b "SUPER + Tab" ''hl.dsp.exec_cmd("rofi -show window")'')
        (b "SUPER + CTRL + Tab" ''function() hl.dispatch(hl.dsp.window.cycle_next()); hl.dispatch(hl.dsp.window.bring_to_top()) end'')
        (b "SUPER + CTRL + SHIFT + Tab" ''hl.dsp.exec_cmd("hyprctl dispatch cyclenext prev; hyprctl dispatch bringactivetotop")'')

        (b "SUPER + N" ''hl.dsp.window.move({ workspace = "special:minimized", follow = false })'')
        # SUPER+SHIFT+N drove two dispatchers in the legacy config (special
        # workspace + notifications); Lua rebinds per key, so both run in one fn.
        (b "SUPER + SHIFT + N" ''function() hl.dispatch(hl.dsp.workspace.toggle_special("minimized")); hl.exec_cmd("swaync-client -t -sw") end'')

        # Scroll through workspaces
        (b "SUPER + mouse_down" ''hl.dsp.focus({ workspace = "e+1" })'')
        (b "SUPER + mouse_up" ''hl.dsp.focus({ workspace = "e-1" })'')

        # Screenshots
        (b "Print" ''hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy')'')
        (b "SHIFT + Print" ''hl.dsp.exec_cmd("grim - | wl-copy")'')
        (b "SUPER + SHIFT + S" ''hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy')'')
        (b "SUPER + P" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/screenshot.sh s")'')
        (b "SUPER + SHIFT + P" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/screenshot.sh sf")'')
        (b "SUPER + CTRL + P" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/screenshot.sh m")'')

        # Screen recording
        (b "SUPER + SHIFT + R" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/screen-record.sh a")'')
        (b "SUPER + CTRL + R" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/screen-record.sh m")'')

        # Utilities
        (b "SUPER + V" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/ClipManager.sh")'')
        (b "SUPER + SHIFT + W" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/wallpaper-select.sh")'')
        (b "SUPER + question" ''hl.dsp.exec_cmd("~/.config/hypr/scripts/keybinds.sh")'')
        (b "SUPER + SHIFT + C" ''hl.dsp.exec_cmd("hyprpicker -a")'')
        (b "SUPER + Escape" ''hl.dsp.exec_cmd("hyprlock")'')
        (b "ALT + Tab" ''hl.dsp.focus({ direction = "down" })'')

        # Mouse drag / resize
        (bf "SUPER + mouse:272" ''hl.dsp.window.drag()'' { mouse = true; })
        (bf "SUPER + mouse:273" ''hl.dsp.window.resize()'' { mouse = true; })

        # Media (locked = works on lockscreen)
        (bf "XF86AudioPlay" ''hl.dsp.exec_cmd("playerctl play-pause")'' { locked = true; })
        (bf "XF86AudioPrev" ''hl.dsp.exec_cmd("playerctl previous")'' { locked = true; })
        (bf "XF86AudioNext" ''hl.dsp.exec_cmd("playerctl next")'' { locked = true; })

        # Volume / brightness (locked + repeating)
        (bf "XF86AudioRaiseVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")'' { locked = true; repeating = true; })
        (bf "XF86AudioLowerVolume" ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")'' { locked = true; repeating = true; })
        (bf "XF86AudioMute" ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")'' { locked = true; repeating = true; })
        (bf "XF86MonBrightnessUp" ''hl.dsp.exec_cmd("brightnessctl set 5%+")'' { locked = true; repeating = true; })
        (bf "XF86MonBrightnessDown" ''hl.dsp.exec_cmd("brightnessctl set 5%-")'' { locked = true; repeating = true; })
      ] ++ wsFocus ++ wsMove ++ wsMoveSilent;

      window_rule = [
        { name = "float-pavucontrol"; match = { class = "^(pavucontrol)$"; }; float = true; }
        { name = "float-thunar-progress"; match = { class = "^(thunar)$"; title = "^(File Operation Progress)$"; }; float = true; }
        { name = "float-yad"; match = { class = "^(yad)$"; }; float = true; }
        { name = "float-pip"; match = { title = "^(Picture-in-Picture)$"; }; float = true; }
        { name = "pin-pip"; match = { title = "^(Picture-in-Picture)$"; }; pin = true; }
        { name = "ghostty-opacity"; match = { class = "^(com.mitchellh.ghostty)$"; }; opacity = "0.95 0.95"; }
      ];
    };
  };

  # Ensure swww is the only wallpaper daemon.
  services.hyprpaper.enable = mkForce false;

  # Without an agent in the session every privileged desktop prompt — NetworkManager
  # editing a connection, udisks2 mounting a disk — fails silently.
  services.hyprpolkitagent.enable = true;

  home.packages = [ pkgs.wdisplays ];
}
