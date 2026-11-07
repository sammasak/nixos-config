# rf-lab pcap fixtures — CRAFTED, not hardware captures

These `.pcap` files are **synthetic 802.11 management frames built offline with
scapy** (`craft-fixtures.py`). They were never transmitted and no radio was
touched — they are forged-on-disk reference traces, not an over-the-air capture.
They exist so `rf:analyze`'s tshark decode logic can be tested deterministically
(issue #40's "offline pcap fixture library … distinguishing observed vs
generated fixtures"). This directory holds **no** over-the-air emitter.

| File | Frame | `wlan.fc.type_subtype` | Reason code |
|------|-------|------------------------|-------------|
| `beacon.pcap` | 3× beacon, SSID `naked-sim-fixture` | `0x0008` | — |
| `deauth.pcap` | deauthentication | `0x000c` | 7 (class-3 frame from nonassociated station) |
| `disassoc.pcap` | disassociation | `0x000a` | 1 (unspecified) |
| `beacon-hidden.pcap` | 5× beacon: empty and NUL-filled (hidden) SSIDs, `x\n\x1b]0;pwn\x07`, `a\xc2\x9bb` (a UTF-8 C1 CSI), `café` | `0x0008` | — |
| `beacon-escape.pcap` | 7× beacon: a literal `a\x0ab`, a bidi override (`invoice` U+202E `fdp.exe`), U+200B/U+00AD/U+FEFF marks, U+2028, non-UTF-8 `\xff\xfeok` and a surrogate `\xed\xa0\x80x`, `日本-ap` | `0x0008` | — |

`beacon-hidden.pcap` (fixed timestamps, so a rerun is byte-identical; SHA256 `ed6e97aa…`) is what
`rf:beacons-test` checks the AP table against: hidden networks read `<hidden>`, control bytes are
`\xNN`, a newline forges no row, UTF-8 survives. Regenerate it alone with
`bash scripts/rf-fixtures-build.sh beacon-hidden`.

`beacon-escape.pcap` (fixed timestamps too) holds the renderings rf-proto's `escape_ssid` (rf-proto#6) applies
beyond C0/C1. `rf:beacons-test` and `checks.rf-beacons-parity` hold the tshark table to them: a backslash is
`\x5c`, bidi/invisible marks and separators are `\u{NNNN}`, a non-UTF-8 SSID is every byte `\xNN`, and CJK
survives. Regenerate it with `bash scripts/rf-fixtures-build.sh beacon-escape`.

Addresses are locally-administered (`02:00:00:00:00:0x`), so they map to no real
device. Link type is `DLT_IEEE802_11` (105) — a bare 802.11 pcap with no
radiotap, exactly what `rf:analyze` reads.

## Regenerate

```bash
bash scripts/rf-fixtures-build.sh      # pins a scapy-capable interpreter
```

## Test the decode

```bash
devenv tasks run rf:analyze-test       # asserts each fixture classifies correctly
devenv tasks run rf:beacons-test       # asserts rf:beacons' AP table, incl. hidden and hostile SSIDs
```

To eyeball one by hand with the real analysis task:

```bash
RF_PCAP=modules/rf-lab/fixtures/deauth.pcap devenv tasks run rf:analyze
```
