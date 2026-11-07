#!/usr/bin/env bash
# Offline check of rf:beacons' AP table (scripts/rf-beacons-table.sh) on the crafted fixtures: the
# plain beacon as before, and the SSIDs it must not print raw (beacon-hidden.pcap: hidden, a forged
# row, terminal escapes, UTF-8; beacon-escape.pcap: a backslash, bidi/invisible marks, non-UTF-8, as
# rf-proto's escape_ssid renders them). No device, no capture. Nonzero on any mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=modules/rf-lab/fixtures
fail=0
check() {
  if [ "$1" = "$2" ]; then echo "  ok   $3"; else
    printf '  FAIL %s\n    got:  %q\n    want: %q\n' "$3" "$1" "$2" >&2; fail=1; fi
}
table() { bash scripts/rf-beacons-table.sh "$dir/$1"; }

check "$(table beacon.pcap)" \
  "02:00:00:00:00:01                3  naked-sim-fixture" \
  "beacon.pcap: one AP, three beacons, its SSID"

want=$(cat <<'EOF'
02:00:00:00:00:11                1  <hidden>
02:00:00:00:00:12                1  <hidden>
02:00:00:00:00:13                1  x\x0a\x1b]0;pwn\x07
02:00:00:00:00:14                1  a\u{009b}b
02:00:00:00:00:15                1  café
EOF
)
got=$(table beacon-hidden.pcap)
check "$got" "$want" "beacon-hidden.pcap: hidden SSIDs, escaped control bytes, UTF-8 intact"
check "$(printf '%s\n' "$got" | wc -l)" 5 "beacon-hidden.pcap: a newline in an SSID forges no row"
if printf '%s' "$got" | LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]\|\xc2[\x80-\x9f]'; then
  check raw-control none "beacon-hidden.pcap: no raw control byte reaches the terminal"
else
  check none none "beacon-hidden.pcap: no raw control byte reaches the terminal"
fi

# beacon-escape.pcap: what rf-proto's escape_ssid escapes beyond C0/C1, rendered the same here
want=$(cat <<'EOF'
02:00:00:00:00:21                1  a\x5cx0ab
02:00:00:00:00:22                1  invoice\u{202e}fdp.exe
02:00:00:00:00:23                1  a\u{200b}b\u{00ad}c\u{feff}d
02:00:00:00:00:24                1  line\u{2028}break
02:00:00:00:00:25                1  \xff\xfe\x6f\x6b
02:00:00:00:00:26                1  \xed\xa0\x80\x78
02:00:00:00:00:27                1  日本-ap
EOF
)
got=$(table beacon-escape.pcap)
check "$got" "$want" "beacon-escape.pcap: backslash, bidi/invisible marks and non-UTF-8 (a surrogate too) escaped; CJK intact"
# the raw UTF-8 of every mark in the fixture (U+200B, U+202E, U+2028, U+00AD, U+FEFF) and a raw 0xff/0xed
if printf '%s' "$got" | LC_ALL=C grep -q $'\xe2\x80\x8b\|\xe2\x80\xae\|\xe2\x80\xa8\|\xc2\xad\|\xef\xbb\xbf\|\xff\|\xed'; then
  check raw-mark none "beacon-escape.pcap: no raw bidi/invisible mark or invalid byte reaches the terminal"
else
  check none none "beacon-escape.pcap: no raw bidi/invisible mark or invalid byte reaches the terminal"
fi

if [ "$fail" = 0 ]; then echo "rf-beacons-test: all fixture tables matched"; else
  echo "rf-beacons-test: table mismatch" >&2; exit 1; fi
