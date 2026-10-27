#!/usr/bin/env python3
"""Craft the offline 802.11 management-frame pcap fixtures for rf-lab.

These are SYNTHETIC frames built with scapy, written straight to disk. Nothing
is transmitted and no radio is touched: this is the "distinguishing observed vs
generated fixtures" deliverable of issue #40 -- labelled, reproducible, CRAFTED
reference traces so rf:analyze's decode logic can be tested without needing a
real over-the-air capture (and without ever forging a frame over the air).

Regenerate:
    nix shell nixpkgs#python3Packages.scapy -c python3 -I craft-fixtures.py
(or run via scripts/rf-fixtures-build.sh, which pins the interpreter).

Link type is DLT_IEEE802_11 (105), exactly what tshark's wlan.* fields decode;
no radiotap header, matching how rf:analyze reads a bare 802.11 pcap.
"""
import pathlib

from scapy.all import Dot11, Dot11Beacon, Dot11Deauth, Dot11Disas, Dot11Elt, wrpcap

HERE = pathlib.Path(__file__).resolve().parent

AP = "02:00:00:00:00:01"      # locally-administered (bit 1 set); never a real device
STA = "02:00:00:00:00:02"
SSID = "naked-sim-fixture"

# wlan.fc.type_subtype the frames decode to, asserted by the classification test.
BEACON_SUBTYPE = 0x08
DEAUTH_SUBTYPE = 0x0C
DISASSOC_SUBTYPE = 0x0A

# Reason codes chosen to match the issue text: deauth 7 (class-3 frame from a
# nonassociated station), disassoc 1 (unspecified). The test asserts on these.
DEAUTH_REASON = 7
DISASSOC_REASON = 1


def beacon():
    frame = (
        Dot11(type=0, subtype=BEACON_SUBTYPE, addr1="ff:ff:ff:ff:ff:ff", addr2=AP, addr3=AP)
        / Dot11Beacon(cap="ESS")
        / Dot11Elt(ID="SSID", info=SSID)
        / Dot11Elt(ID="DSset", info=bytes([6]))
    )
    return [frame] * 3


def deauth():
    return [
        Dot11(type=0, subtype=DEAUTH_SUBTYPE, addr1=STA, addr2=AP, addr3=AP)
        / Dot11Deauth(reason=DEAUTH_REASON)
    ]


def disassoc():
    return [
        Dot11(type=0, subtype=DISASSOC_SUBTYPE, addr1=STA, addr2=AP, addr3=AP)
        / Dot11Disas(reason=DISASSOC_REASON)
    ]


def main():
    for name, frames in (("beacon", beacon()), ("deauth", deauth()), ("disassoc", disassoc())):
        out = HERE / f"{name}.pcap"
        wrpcap(str(out), frames)
        print(f"wrote {out} ({len(frames)} frame(s))")


if __name__ == "__main__":
    main()
