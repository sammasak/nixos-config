#!/usr/bin/env bash
# Deterministic, offline check that rf:analyze's tshark decode logic recognises
# each crafted fixture: beacon counted, deauth detected with its reason code,
# disassoc detected with its reason code. No device, no capture, no network --
# reads only the committed pcaps under modules/rf-lab/fixtures. Nonzero on any
# mismatch so the git hooks / CI catch a decode regression.
set -euo pipefail
cd "$(dirname "$0")/.."

dir=modules/rf-lab/fixtures
fail=0

check() {
  if [ "$1" = "$2" ]; then
    echo "  ok   $3"
  else
    echo "  FAIL $3 (got '$1', want '$2')" >&2
    fail=1
  fi
}

# Same filters rf:analyze uses: mgmt subtype 0x0008 beacon, 0x000c deauth,
# 0x000a disassoc, reason code from wlan.fixed.reason_code.
subtype_count() {
  tshark -r "$dir/$1" -Y "wlan.fc.type_subtype==$2" -T fields -e wlan.fc.type_subtype 2>/dev/null | grep -c .
}
reason_for() {
  tshark -r "$dir/$1" -Y "wlan.fc.type_subtype==$2" -T fields -e wlan.fixed.reason_code 2>/dev/null | head -1
}

echo "== beacon fixture:"
beacons=$(subtype_count beacon.pcap 0x0008)
check "$beacons" 3 "beacon.pcap: 3 beacon frames counted"

echo "== deauth fixture:"
deauths=$(subtype_count deauth.pcap 0x000c)
check "$deauths" 1 "deauth.pcap: deauth frame detected"
check "$(reason_for deauth.pcap 0x000c)" 0x0007 "deauth.pcap: reason code 7"

echo "== disassoc fixture:"
disas=$(subtype_count disassoc.pcap 0x000a)
check "$disas" 1 "disassoc.pcap: disassoc frame detected"
check "$(reason_for disassoc.pcap 0x000a)" 0x0001 "disassoc.pcap: reason code 1"

if [ "$fail" = 0 ]; then
  echo "rf-analyze-test: all fixture classifications matched"
else
  echo "rf-analyze-test: fixture classification mismatch" >&2
  exit 1
fi
