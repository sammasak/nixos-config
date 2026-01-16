#!/usr/bin/env bash
set -euo pipefail

# Hyprland window switcher using rofi (HyprCrux-style)
# Properly switches workspace, focuses window, and brings it to top

# 1) Get all clients (windows) from Hyprland, filter mapped windows only
clients_json="$(hyprctl clients -j)"

# 2) Build window list with address, workspace, class, title
# Format: address\tworkspace\tclass\ttitle
menu="$(
  jq -r '
    .[]
    | select(.mapped == true)
    | [
        .address,
        (if .workspace.name != null then .workspace.name else (.workspace.id|tostring) end),
        (.class // ""),
        (.title // "")
      ]
    | @tsv
  ' <<<"$clients_json" \
  | sort -k2,2 -k3,3 -k4,4
)"

# Exit if no windows
[[ -z "${menu}" ]] && exit 0

# 3) Show in rofi with formatted display
# Display format: [workspace] class — title
chosen="$(
  awk -F'\t' '{
    addr=$1; ws=$2; cls=$3; title=$4;
    printf "[%s] %s — %s\n", ws, cls, title
  }' <<<"$menu" \
  | rofi -dmenu -i -p "Window" \
    -format "i" \
    -no-custom
)"

[[ -z "${chosen}" ]] && exit 0

# Get the selected line from original menu (chosen is the line index)
selected_line="$(sed -n "$((chosen + 1))p" <<<"$menu")"
addr="$(cut -f1 <<<"$selected_line")"
ws="$(cut -f2 <<<"$selected_line")"

# 4) Jump to workspace, focus window, bring to top
# Chain all commands together with && to ensure they execute in order
hyprctl dispatch workspace "$ws" && \
  sleep 0.15 && \
  hyprctl dispatch focuswindow "address:$addr" && \
  sleep 0.1 && \
  hyprctl dispatch bringactivetotop
