{ osConfig ? null, ... }:
let
  baseProfile =
    if osConfig != null && osConfig ? sam && osConfig.sam ? profile
    then osConfig.sam.profile
    else { };
  kbdLayout = baseProfile.kbdLayout or "se";
in
{
  # niri has no config of its own otherwise, so it falls back to the compiled-in
  # default — which spawns its own waybar (a second bar on top of waybar.service)
  # and uses niri's default binds instead of these.
  xdg.configFile."niri/config.kdl".text = ''
    input {
        keyboard {
            xkb {
                layout "${kbdLayout}"
            }
            numlock
        }

        touchpad {
            tap
            dwt
            natural-scroll
        }

        focus-follows-mouse
    }

    // xwayland-satellite is NOT spawned: niri 26.04 integrates it on-demand
    // (creates the X11 sockets, exports DISPLAY) as long as the binary is on PATH.
    // waybar is NOT spawned: waybar.service already runs it; spawning here doubles it.

    // These live in Hyprland's start hook, which never runs under niri; without
    // them Mod+V opens an empty clipboard history and polkit prompts fail silently.
    spawn-sh-at-startup "wl-paste --type text --watch cliphist store"
    spawn-sh-at-startup "wl-paste --type image --watch cliphist store"
    spawn-at-startup "systemctl" "--user" "start" "hyprpolkitagent.service"

    layout {
        gaps 16
        center-focused-column "never"

        preset-column-widths {
            proportion 0.33333
            proportion 0.5
            proportion 0.66667
            proportion 1.0
        }

        // 1.0, not niri's usual 0.5: new windows opening half-width reads as
        // broken to a Hyprland-master-layout user. Mod+R cycles the presets.
        default-column-width { proportion 1.0; }

        focus-ring {
            width 4
            active-color "#ca9ee6"
            inactive-color "#6c7086"
        }

        border {
            off
            width 4
        }
    }

    prefer-no-csd

    screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

    window-rule {
        match app-id=r#"firefox$"# title="^Picture-in-Picture$"
        open-floating true
    }

    binds {
        // Programs
        Mod+Return       hotkey-overlay-title="Terminal" { spawn "ghostty"; }
        Mod+Shift+Return hotkey-overlay-title="Terminal" { spawn "ghostty"; }
        Mod+D     hotkey-overlay-title="Launcher" { spawn "rofi" "-show" "drun"; }
        Mod+A     hotkey-overlay-title="Launcher" { spawn "rofi" "-show" "drun"; }
        Mod+Space hotkey-overlay-title="Launcher" { spawn "rofi" "-show" "drun"; }
        Mod+E { spawn "ghostty" "-e" "yazi"; }
        Mod+B { spawn "firefox"; }

        // Session / window management
        Mod+Q repeat=false { close-window; }
        Mod+Shift+Q { quit; }
        Mod+F hotkey-overlay-title="Maximize column width" { maximize-column; }
        Mod+W { toggle-window-floating; }

        // Focus: columns = left/right, windows in a column = up/down
        Mod+H { focus-column-left; }
        Mod+L { focus-column-right; }
        Mod+K { focus-window-up; }
        Mod+J { focus-window-down; }

        // Move
        Mod+Shift+H { move-column-left; }
        Mod+Shift+L { move-column-right; }
        Mod+Shift+K { move-window-up; }
        Mod+Shift+J { move-window-down; }

        // Resize: column width (H/L), window height (K/J)
        Mod+Ctrl+H hotkey-overlay-title="Shrink column 10%" { set-column-width "-10%"; }
        Mod+Ctrl+L hotkey-overlay-title="Grow column 10%" { set-column-width "+10%"; }
        Mod+Ctrl+K { set-window-height "-10%"; }
        Mod+Ctrl+J { set-window-height "+10%"; }

        // niri idioms: column sizing is per-column, so these are the dynamic
        // levers — R cycles presets, M snaps full, Shift+M fills leftover space.
        Mod+Comma  hotkey-overlay-title="Stack window into column" { consume-window-into-column; }
        Mod+Period hotkey-overlay-title="Unstack window from column" { expel-window-from-column; }
        Mod+R hotkey-overlay-title="Cycle width: 1/3 - 1/2 - 2/3 - full" { switch-preset-column-width; }
        Mod+M { fullscreen-window; }
        Mod+Shift+M hotkey-overlay-title="Expand into leftover space" { expand-column-to-available-width; }
        Mod+C hotkey-overlay-title="Center column" { center-column; }

        // Workspaces (dynamic; index reference is best-effort)
        Mod+1 { focus-workspace 1; }
        Mod+2 { focus-workspace 2; }
        Mod+3 { focus-workspace 3; }
        Mod+4 { focus-workspace 4; }
        Mod+5 { focus-workspace 5; }
        Mod+6 { focus-workspace 6; }
        Mod+7 { focus-workspace 7; }
        Mod+8 { focus-workspace 8; }
        Mod+9 { focus-workspace 9; }
        Mod+0 { focus-workspace 10; }

        Mod+Shift+1 { move-column-to-workspace 1; }
        Mod+Shift+2 { move-column-to-workspace 2; }
        Mod+Shift+3 { move-column-to-workspace 3; }
        Mod+Shift+4 { move-column-to-workspace 4; }
        Mod+Shift+5 { move-column-to-workspace 5; }
        Mod+Shift+6 { move-column-to-workspace 6; }
        Mod+Shift+7 { move-column-to-workspace 7; }
        Mod+Shift+8 { move-column-to-workspace 8; }
        Mod+Shift+9 { move-column-to-workspace 9; }
        Mod+Shift+0 { move-column-to-workspace 10; }

        // Scroll to switch workspaces
        Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
        Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
        Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
        Mod+Ctrl+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }

        // Screenshots + scripts kept from the Hyprland setup
        Print       { screenshot; }
        Mod+Shift+S { screenshot; }
        Mod+P       { spawn-sh "~/.config/hypr/scripts/screenshot.sh s"; }
        Mod+Shift+P { spawn-sh "~/.config/hypr/scripts/screenshot.sh sf"; }
        // Not screenshot.sh m: its monitor mode resolves the output via hyprctl.
        Mod+Ctrl+P  { screenshot-screen; }
        Mod+Shift+R { spawn-sh "~/.config/hypr/scripts/screen-record.sh a"; }
        Mod+Ctrl+R  { spawn-sh "~/.config/hypr/scripts/screen-record.sh m"; }
        Mod+V { spawn-sh "~/.config/hypr/scripts/ClipManager.sh"; }
        Mod+Shift+W { spawn-sh "~/.config/hypr/scripts/wallpaper-select.sh"; }
        // Mod+Shift+Plus, not Mod+Shift+Slash: niri binds match the unshifted
        // keysym, and on the se layout "?" lives on the plus key — Slash would
        // resolve to Shift+7 and lose to the workspace bind.
        Mod+Shift+Plus hotkey-overlay-title="Full keybinds cheatsheet" { spawn-sh "~/.config/hypr/scripts/keybinds.sh"; }
        Mod+F1 hotkey-overlay-title="Show this overlay" { show-hotkey-overlay; }
        Mod+Shift+C { spawn "hyprpicker" "-a"; }
        Mod+Shift+N { spawn "swaync-client" "-t" "-sw"; }

        // Lock
        Mod+Escape { spawn "hyprlock"; }

        // Media / brightness (work while locked)
        XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+ -l 1.0"; }
        XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-"; }
        XF86AudioMute        allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
        XF86AudioPlay        allow-when-locked=true { spawn-sh "playerctl play-pause"; }
        XF86AudioPrev        allow-when-locked=true { spawn-sh "playerctl previous"; }
        XF86AudioNext        allow-when-locked=true { spawn-sh "playerctl next"; }
        XF86MonBrightnessUp   allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "+5%"; }
        XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "--class=backlight" "set" "5%-"; }
    }
  '';
}
