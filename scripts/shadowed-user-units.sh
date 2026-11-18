#!/usr/bin/env bash
# Warns, never fails, when a file in a user's ~/.config/systemd/user shadows a NixOS user unit of the same name
# (/etc/systemd/user), or a NAME.d directory there overrides one: systemd reads the user's copy first, so a deploy
# changes nothing for that user. Run by every activation as root (modules/core/users.nix), so the warning is in the
# deploy's output; the post-deploy check cannot read homes. A copy that resolves to the same file is not a warning.
# Usage: shadowed-user-units.sh HOME...   SYSTEM_USER_UNITS overrides /etc/systemd/user (scripts/test-deploy-recipes.py).
set -uo pipefail

units=${SYSTEM_USER_UNITS:-/etc/systemd/user}
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
    if [ "$n" != "$base" ]; then
      echo "warning: $f overrides the NixOS user unit $base ($units); this deploy's version is not what runs for that user" >&2
    elif [ "$(readlink -f "$f")" != "$(readlink -f "$units/$n")" ]; then
      echo "warning: $f shadows the NixOS user unit $n ($units): the home's copy runs, so this deploy does not change it for that user" >&2
    fi
  done
done
exit 0
