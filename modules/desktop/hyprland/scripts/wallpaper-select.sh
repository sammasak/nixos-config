#!/usr/bin/env bash
# Wallpaper selector using rofi and swww

# Ensure swww daemon is running
if ! swww query &> /dev/null; then
  swww init &> /dev/null
fi

# Check multiple locations for wallpapers
WALLPAPER_DIRS=(
  "$HOME/.config/wallpapers"
  "/run/current-system/sw/share/wallpapers"
  "/etc/nixos/assets/wallpapers"
  "$HOME/nixos-config/assets/wallpapers"
)

WALLPAPER_DIR=""
for dir in "${WALLPAPER_DIRS[@]}"; do
  if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
    WALLPAPER_DIR="$dir"
    break
  fi
done

if [ -z "$WALLPAPER_DIR" ]; then
  notify-send "Wallpaper" "No wallpaper directory found"
  exit 1
fi

# Find wallpapers
wallpapers=$(fd -e jpg -e jpeg -e png -e gif -e webp . "$WALLPAPER_DIR" 2>/dev/null)

if [ -z "$wallpapers" ]; then
  notify-send "Wallpaper" "No wallpapers found in $WALLPAPER_DIR"
  exit 1
fi

# Show selection in rofi
selected=$(echo "$wallpapers" | while read -r img; do
  basename "$img"
done | rofi -dmenu -p "Wallpaper" -i)

if [ -z "$selected" ]; then
  exit 0
fi

# Find full path
wallpaper_path=$(fd -e jpg -e jpeg -e png -e gif -e webp "^${selected}$" "$WALLPAPER_DIR" 2>/dev/null | head -n1)

if [ -n "$wallpaper_path" ]; then
  swww img "$wallpaper_path" --transition-type wipe --transition-duration 2
  notify-send "Wallpaper" "Set to $selected"
fi
