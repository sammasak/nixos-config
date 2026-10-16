#!/usr/bin/env bash
# Regenerate the crafted rf-lab pcap fixtures from craft-fixtures.py, pinning a
# scapy-capable interpreter so `nix shell nixpkgs#python3Packages.scapy -c
# python3` (which ships the library but not a matching interpreter on PATH) is
# not relied on. Offline frame synthesis only; nothing is transmitted.
set -euo pipefail
cd "$(dirname "$0")/.."

scapy=$(nix build --no-link --print-out-paths nixpkgs#python3Packages.scapy)
py=$(nix build --no-link --print-out-paths nixpkgs#python314)
site=$(echo "$scapy"/lib/python3.*/site-packages)

PYTHONPATH="$site" "$py/bin/python3" modules/rf-lab/fixtures/craft-fixtures.py
