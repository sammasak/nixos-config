#!/usr/bin/env bash
# The running NixOS generation as node-exporter textfile metrics (modules/homelab/monitoring/node-exporter.nix runs it
# at activation). Usage: nixos-textfile.sh DIR SYSTEM PROFILES: SYSTEM is the activated toplevel, PROFILES the
# directory holding system and system-<n>-link. The generation is the profile's when it is SYSTEM, else the newest
# link that resolves to SYSTEM (a boot or rollback into an older one); none for a specialisation or a test switch.
set -eu
dir=$1 system=$(readlink -f "$2") profiles=$3
mkdir -p "$dir"
gen=
if [ "$(readlink -f "$profiles/system")" = "$system" ]; then
  gen=$(readlink "$profiles/system")
else
  for link in "$profiles"/system-*-link; do
    [ "$(readlink -f "$link")" = "$system" ] || continue
    n=${link##*/system-}
    n=${n%-link}
    if [ -z "$gen" ] || [ "$n" -gt "${gen#system-}" ]; then gen=system-$n; fi
  done
fi
gen=${gen#system-}
gen=${gen%-link}
tmp=$(mktemp "$dir/.nixos.prom.XXXXXX")
{
  printf 'homelab_nixos_info{version="%s",toplevel="%s"} 1\n' "$(cat "$system/nixos-version")" "$(basename "$system" | cut -d- -f1)"
  if [ -n "$gen" ]; then printf 'homelab_nixos_generation %s\n' "$gen"; fi
} >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$dir/nixos.prom"
