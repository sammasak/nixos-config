#!/usr/bin/env bash
# The AP table rf:beacons prints for a capture: one row per BSSID (channel, strongest dBm, beacon
# count, SSID), from tshark's fields. The SSID is untrusted bytes from anyone in radio range, so it is
# never printed raw. It renders exactly as rf-proto's escape_ssid (rf-proto#6), which
# checks.rf-beacons-parity holds it to: an empty (`<MISSING>` from tshark) or all-zero SSID is
# `<hidden>`; an SSID that is not valid UTF-8 (std::str::from_utf8: no overlong, surrogate or
# truncated sequence, nothing past U+10FFFF) is every byte as \xNN; otherwise a backslash is \x5c (so
# a literal "\x0a" cannot pass for an escaped newline), C0/DEL are \xNN, C1 (U+0080-009F) and the
# bidi overrides, invisible marks and line/paragraph separators a terminal may reorder or hide are
# \u{NNNN}, and everything else prints as itself. Rows sort by channel, then BSSID.
#
# usage: rf-beacons-table.sh CAPTURE.pcap   (tshark and gawk on PATH)
set -euo pipefail
tshark -r "$1" -Y 'wlan.fc.type_subtype==0x08' -T fields \
    -e wlan.bssid -e wlan.ssid -e wlan_radio.channel -e wlan_radio.signal_dbm 2>/dev/null \
  | LC_ALL=C gawk -F'\t' '
      # the SSID bytes (tshark prints the field as hex) into B[1..n]; returns n
      function bytes(h,  n, i) {
        n = length(h) / 2
        for (i = 1; i <= n; i++) B[i] = strtonum("0x" substr(h, 2 * i - 1, 2))
        return n
      }
      # length of the valid UTF-8 sequence at B[i], or 0: the ranges std::str::from_utf8 accepts
      function seqlen(i, n,  b, k, lo, hi, j) {
        b = B[i]
        if (b < 128) return 1
        if (b >= 194 && b <= 223) k = 2
        else if (b >= 224 && b <= 239) k = 3
        else if (b >= 240 && b <= 244) k = 4
        else return 0
        if (i + k - 1 > n) return 0
        lo = 128; hi = 191
        if (b == 224) { lo = 160 } else if (b == 237) { hi = 159 } else if (b == 240) { lo = 144 } else if (b == 244) { hi = 143 }
        if (B[i + 1] < lo || B[i + 1] > hi) return 0
        for (j = 2; j < k; j++) if (B[i + j] < 128 || B[i + j] > 191) return 0
        return k
      }
      # the code point of the k-byte sequence at B[i]
      function cp(i, k) {
        if (k == 1) return B[i]
        if (k == 2) return (B[i] - 192) * 64 + B[i + 1] - 128
        if (k == 3) return (B[i] - 224) * 4096 + (B[i + 1] - 128) * 64 + B[i + 2] - 128
        return (B[i] - 240) * 262144 + (B[i + 1] - 128) * 4096 + (B[i + 2] - 128) * 64 + B[i + 3] - 128
      }
      # bidi overrides, invisible format marks and line/paragraph separators (the escape_ssid list)
      function invisible(c) {
        return c == 173 || c == 1564 || c == 6158 || (c >= 8203 && c <= 8207) || (c >= 8234 && c <= 8238) \
          || (c >= 8288 && c <= 8292) || (c >= 8294 && c <= 8297) || c == 65279 || c == 8232 || c == 8233
      }
      function ssid(h,  n, i, k, c, r, j) {
        if (h == "" || h == "<MISSING>" || h ~ /^(00)+$/) return "<hidden>"
        n = bytes(h); r = ""
        for (i = 1; i <= n; i += k) if (!(k = seqlen(i, n))) break
        if (i <= n) {  # not UTF-8: every byte escaped
          for (i = 1; i <= n; i++) r = r sprintf("\\x%02x", B[i])
          return r
        }
        for (i = 1; i <= n; i += k) {
          k = seqlen(i, n); c = cp(i, k)
          if (c == 92 || c < 32 || c == 127) r = r sprintf("\\x%02x", c)
          else if ((c >= 128 && c <= 159) || invisible(c)) r = r sprintf("\\u{%04x}", c)
          else for (j = 0; j < k; j++) r = r sprintf("%c", B[i + j])
        }
        return r
      }
      { b = $1; if (b == "") next
        n[b]++; ch[b] = $3; name[b] = ssid($2)
        if (sig[b] == "" || ($4 + 0) > (sig[b] + 0)) sig[b] = $4 }
      END { for (b in n) printf "%-18s %3s %5s %5s  %s\n", b, ch[b], sig[b], n[b], name[b] }' \
  | LC_ALL=C sort -k2,2n -k1,1
