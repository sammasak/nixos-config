#!/usr/bin/env bash
# The hosts table (flake-modules/hosts.nix) read as text, without Nix, for the Justfile's HOST recipes and
# scripts/ssh-known-hosts-verify.sh: an entry is a `    <name> = {` line; its host directory is `hostDir = "…"` on that
# line, else the name (hosts-option.nix's default). scripts/test-ssh-known-hosts.py holds the names to the evaluated
# deploy nodes and the directories to their hostNames.
#   hosts-table.sh nodes        the entry names, one per line
#   hosts-table.sh hostnames    the host directories (= hostNames), one per line
#   hosts-table.sh check NAME   exit 0 if NAME is an entry, else 1 naming the entries
# Exit 2 when no entry can be read. HOSTS_TABLE overrides the file (the test's seeds).
set -euo pipefail
table=${HOSTS_TABLE:-$(dirname "$0")/../flake-modules/hosts.nix}
rows=$(awk '/^    [A-Za-z0-9][A-Za-z0-9-]* = \{/ {
  dir = $1; if (match($0, /hostDir = "[^"]+"/)) dir = substr($0, RSTART + 11, RLENGTH - 12); print $1, dir }' "$table") || rows=""
[ -n "$rows" ] || { echo "hosts-table: no entry read from $table" >&2; exit 2; }
case ${1:-} in
  nodes) cut -d' ' -f1 <<<"$rows" ;;
  hostnames) cut -d' ' -f2 <<<"$rows" ;;
  check)
    [ $# -eq 2 ] || { echo "usage: hosts-table.sh check NAME" >&2; exit 2; }
    cut -d' ' -f1 <<<"$rows" | grep -qxF -- "$2" && exit 0
    echo "unknown host '$2': not an entry of flake-modules/hosts.nix ($(cut -d' ' -f1 <<<"$rows" | paste -sd' '))" >&2
    exit 1
    ;;
  *) echo "usage: hosts-table.sh nodes|hostnames|check NAME" >&2; exit 2 ;;
esac
