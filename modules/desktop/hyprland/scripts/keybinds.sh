#!/usr/bin/env bash

if pidof rofi >/dev/null; then
  pkill rofi
fi

if pidof yad >/dev/null; then
  pkill yad
fi

yad \
  --center \
  --title="Hyprland Keybinds" \
  --no-buttons \
  --list \
  --width=745 \
  --height=920 \
  --column=Key: \
  --column=Description: \
  --column=Command: \
  --timeout-indicator=bottom \
  "SUPER Return" "Launch terminal" "kitty" \
  "SUPER D" "Launch application menu" "rofi -show drun" \
  "SUPER E" "Launch file manager" "thunar" \
  "SUPER B" "Launch browser" "firefox" \
  "SUPER Q" "Close active window" "killactive" \
  "SUPER SHIFT Q" "Exit Hyprland session" "exit" \
  "SUPER F" "Toggle fullscreen" "fullscreen" \
  "SUPER Space" "Toggle floating" "togglefloating" \
  "SUPER C" "Center window" "centerwindow" \
  "SUPER Y" "Pin window" "pin" \
  "SUPER H/J/K/L" "Move focus" "movefocus" \
  "SUPER SHIFT H/J/K/L" "Move window" "movewindow" \
  "SUPER CTRL H/J/K/L" "Resize window" "resizeactive" \
  "SUPER I" "Add master" "layoutmsg addmaster" \
  "SUPER O" "Remove master" "layoutmsg removemaster" \
  "SUPER CTRL Return" "Swap with master" "swapwithmaster" \
  "SUPER 1-0" "Switch to workspace 1-10" "workspace 1-10" \
  "SUPER SHIFT 1-0" "Move to workspace 1-10" "movetoworkspace" \
  "SUPER W" "Toggle notifications" "swaync-client -t -sw" \
  "SUPER Escape" "Lock screen" "hyprlock" \
  "SUPER P" "Screenshot (select area)" "screenshot.sh s" \
  "SUPER SHIFT P" "Screenshot (frozen)" "screenshot.sh sf" \
  "Print" "Screenshot (area to clipboard)" "grim + slurp" \
  "SUPER V" "Clipboard manager" "ClipManager.sh" \
  "SUPER SHIFT R" "Screen record (area)" "screen-record.sh a" \
  "SUPER CTRL R" "Screen record (monitor)" "screen-record.sh m" \
  "SUPER SHIFT W" "Wallpaper selector" "wallpaper-select" \
  "SUPER SHIFT C" "Color picker" "hyprpicker -a" \
  "SUPER N" "Minimize to scratchpad" "movetoworkspacesilent special:minimized" \
  "SUPER SHIFT N" "Toggle minimized" "togglespecialworkspace minimized" \
  "XF86AudioRaiseVolume" "Volume up" "wpctl set-volume +5%" \
  "XF86AudioLowerVolume" "Volume down" "wpctl set-volume -5%" \
  "XF86AudioMute" "Mute audio" "wpctl set-mute toggle" \
  "XF86MonBrightnessUp" "Brightness up" "brightnessctl +5%" \
  "XF86MonBrightnessDown" "Brightness down" "brightnessctl -5%" \
  "XF86AudioPlay" "Play/Pause media" "playerctl play-pause" \
  "XF86AudioNext" "Next track" "playerctl next" \
  "XF86AudioPrev" "Previous track" "playerctl previous"
