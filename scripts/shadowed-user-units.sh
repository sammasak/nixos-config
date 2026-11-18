#!/usr/bin/env bash
# Warns, never fails, when a file in a user's ~/.config/systemd/user shadows a NixOS user unit of the same name
# (/etc/systemd/user), or a NAME.d directory there overrides one: systemd reads the user's copy first, so a deploy
# changes nothing for that user. Run by every activation as root (modules/core/users.nix), so the warning is in the
# deploy's output. The post-deploy check cannot read homes, so with SHADOW_REPORT set the same lines also go to that
# file, readable by all and written even when empty, and scripts/post-deploy-check.sh fails on a line in it. A copy that
# resolves to the same file is not a warning.
# Usage: shadowed-user-units.sh HOME...   SYSTEM_USER_UNITS overrides /etc/systemd/user (scripts/test-deploy-recipes.py).
set -uo pipefail

units=${SYSTEM_USER_UNITS:-/etc/systemd/user}
found=()
for home in "$@"; do
  dir=$home/.config/systemd/user
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=${f##*/}
    # unit files and their NAME.d drop-in directories only: a *.target.wants directory (Home Manager makes them) adds
    # to the unit, it does not shadow it
    case $n in
      *.service | *.socket | *.timer | *.target | *.path | *.mount | *.automount | *.slice | *.swap) base=$n ;;
      *.service.d | *.socket.d | *.timer.d | *.target.d | *.path.d | *.mount.d | *.automount.d | *.slice.d | *.swap.d) base=${n%.d} ;;
      *) continue ;;
    esac
    [ -e "$units/$base" ] || continue
    # %q: a file name is the user's, and goes to the deploy's output
    if [ "$n" != "$base" ]; then
      found+=("$(printf '%q overrides the NixOS user unit %q (%s); this deploy'"'"'s version is not what runs for that user' "$f" "$base" "$units")")
    elif [ "$(readlink -f "$f")" != "$(readlink -f "$units/$n")" ]; then
      found+=("$(printf '%q shadows the NixOS user unit %q (%s): the home'"'"'s copy runs, so this deploy does not change it for that user' "$f" "$n" "$units")")
    fi
  done
done
for line in "${found[@]}"; do echo "warning: $line" >&2; done
if [ -n "${SHADOW_REPORT:-}" ]; then
  # replaced whole, so the check never reads half a report
  tmp=""
  if ! { tmp=$(mktemp "$SHADOW_REPORT.XXXXXX") && chmod 0644 "$tmp" &&
    { [ "${#found[@]}" -eq 0 ] || printf '%s\n' "${found[@]}"; } >"$tmp" && mv -f "$tmp" "$SHADOW_REPORT"; }; then
    echo "warning: could not write $SHADOW_REPORT; the post-deploy check cannot see shadowed user units" >&2
    rm -f "$tmp"
  fi
fi
exit 0
