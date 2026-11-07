#!/usr/bin/env bash
# The AP table rf:beacons prints for a capture: one row per BSSID (channel, strongest dBm, beacon
# count, SSID), from tshark's fields. The SSID is untrusted bytes from anyone in radio range, so it is
# never printed raw: C0/DEL controls become \xNN and a UTF-8 C1 (U+0080-009F) becomes \u{00NN} (rf-proto#6, disjoint from a raw high byte), and an empty
# (`<MISSING>` from tshark) or all-zero SSID is `<hidden>`. Rows sort by channel, then BSSID.
#
# usage: rf-beacons-table.sh CAPTURE.pcap   (tshark and gawk on PATH)
set -euo pipefail
tshark -r "$1" -Y 'wlan.fc.type_subtype==0x08' -T fields \
    -e wlan.bssid -e wlan.ssid -e wlan_radio.channel -e wlan_radio.signal_dbm 2>/dev/null \
  | LC_ALL=C gawk -F'\t' '
      function ssid(h,  r, i, c, d) {
        if (h == "" || h == "<MISSING>" || h ~ /^(00)+$/) return "<hidden>"
        r = ""
        for (i = 1; i <= length(h); i += 2) {
          c = strtonum("0x" substr(h, i, 2))
          d = strtonum("0x" substr(h, i + 2, 2))
          if (c < 32 || c == 127) r = r sprintf("\\x%02x", c)
          else if (c == 194 && d >= 128 && d <= 159) { r = r sprintf("\\u{00%02x}", d); i += 2 }
          else r = r sprintf("%c", c)
        }
        return r
      }
      { b = $1; if (b == "") next
        n[b]++; ch[b] = $3; name[b] = ssid($2)
        if (sig[b] == "" || ($4 + 0) > (sig[b] + 0)) sig[b] = $4 }
      END { for (b in n) printf "%-18s %3s %5s %5s  %s\n", b, ch[b], sig[b], n[b], name[b] }' \
  | LC_ALL=C sort -k2,2n -k1,1
