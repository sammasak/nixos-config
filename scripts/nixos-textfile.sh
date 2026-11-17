#!/usr/bin/env bash
# The running NixOS generation as node-exporter textfile metrics (modules/homelab/monitoring/node-exporter.nix runs it
# at activation). Usage: nixos-textfile.sh DIR SYSTEM PROFILES: SYSTEM is the activated toplevel, PROFILES the
# directory holding system-<n>-link. The generation is the link that resolves to SYSTEM, so a boot into an older one
# reports that one.
set -eu
dir=$1 system=$2 profiles=$3
mkdir -p "$dir"
toplevel=$(basename "$(readlink -f "$system")")
gen=
for link in "$profiles"/system-*-link; do
  [ "$(readlink -f "$link")" = "$(readlink -f "$system")" ] || continue
  gen=${link##*/system-}
  gen=${gen%-link}
done
tmp=$(mktemp "$dir/.nixos.prom.XXXXXX")
{
  printf 'homelab_nixos_info{version="%s",toplevel="%s"} 1\n' "$(cat "$system/nixos-version")" "${toplevel%%-*}"
  if [ -n "$gen" ]; then printf 'homelab_nixos_generation %s\n' "$gen"; fi
  printf 'homelab_nixos_activated_seconds %s\n' "$(date +%s)"
} >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$dir/nixos.prom"
