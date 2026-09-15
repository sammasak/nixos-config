#!/usr/bin/env bash

XDG_VIDEOS_DIR="${XDG_VIDEOS_DIR:-$HOME/Videos}"
DIR="${XDG_VIDEOS_DIR}/screen-record"

# Create output dir if it doesn't exist
mkdir -p $DIR

print_error() {
  cat <<EOF
Usage: $(basename "$0") <action>
Valid actions:
  a  : Select area
  m  : Select monitor
EOF
  exit 1
}

# Generate a timestamp
timestamp=$(date +"%Y%m%d_%Hh%Mm%Ss")

if pidof wf-recorder >/dev/null; then
  pkill wf-recorder
  notify-send -e -t 2500 -u low "Recording Finished" \
    "Saved to $DIR/recording_${timestamp}.mp4"
  exit 0
fi

case "$1" in
a) REGION=$(slurp) ;;
m) REGION=$(slurp -o) ;;
*) print_error ;;
esac

# Start recording with wf-recorder and save to a file with the timestamp
wf-recorder --audio -g "$REGION" -f "$DIR/recording_${timestamp}.mp4" &
notify-send -e -t 2500 -u low "Recording Started"
