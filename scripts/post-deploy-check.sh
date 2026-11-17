#!/usr/bin/env bash
# The unit half of `just deploy`'s post-deploy check, run on the target as the deploy user (ssh … bash -s < this; no
# root needed). Exits 1 if the system is not running (a failed unit leaves it degraded) or a unit is in a restart loop:
# waiting to restart (auto-restart) or activating again after a restart, as ollama does with no start limit while its
# bind address is missing (ollama-host.nix). is-system-running reads both as running. Units whose condition skipped
# them are listed, not failed: a skip is often intended.
set -uo pipefail

rc=0
state=$(systemctl is-system-running --wait) || { echo "post-deploy: system is ${state:-unknown}" >&2; rc=1; }

# `show '*'` matches active units only, so a skipped (inactive) unit needs --all from list-units. One block per
# unit; a property a unit type lacks (NRestarts off services) is printed empty.
mapfile -t units < <(systemctl list-units --all --plain --no-legend --full | awk '{ sub(/^●/, ""); print $1 }')
report=$(systemctl show -p Id -p ActiveState -p SubState -p NRestarts -p ConditionResult \
  -p ConditionTimestampMonotonic -- "${units[@]}" | awk -v RS= -F '\n' '{
    delete p; for (i = 1; i <= NF; i++) { k = substr($i, 1, index($i, "=") - 1); p[k] = substr($i, length(k) + 2) }
    if (p["ActiveState"] == "failed") print "failed " p["Id"]
    else if (p["SubState"] == "auto-restart" || (p["ActiveState"] == "activating" && p["NRestarts"] + 0 > 0))
      print "looping " p["Id"] " (" p["ActiveState"] "/" p["SubState"] ", " p["NRestarts"] + 0 " restarts)"
    else if (p["ConditionResult"] == "no" && p["ConditionTimestampMonotonic"] + 0 > 0) print "skipped " p["Id"]
  }') || { echo "post-deploy: could not read the unit states" >&2; exit 1; }

skipped=()
while read -r kind unit; do
  case $kind in
    failed) echo "post-deploy: failed unit: $unit" >&2 ;;
    looping) echo "post-deploy: unit in a restart loop: $unit" >&2; rc=1 ;;
    skipped) skipped+=("$unit") ;;
  esac
done <<<"$report"
[ "${#skipped[@]}" -eq 0 ] || echo "post-deploy: condition skipped (not a failure): ${skipped[*]}"
exit "$rc"
