# rf-lab: naked-pi passive Wi-Fi observation kit

Opt-in, **observation-only** 2.4 GHz tooling for the `naked-pi` host (Raspberry
Pi 3, role `rf-lab`). Capture and standard discovery only — no deauthentication,
frame injection, jamming or AP mode lives here. Operated from lenovo over SSH.

## Enable

Set in a host's config (the `rf-lab` role does this):

```nix
sam.rfLab.enable = true;          # installs the kit + narrow sudo
# sam.rfLab.captureDir    = "/var/lib/rf-lab/captures";   # aged out
# sam.rfLab.retentionDays = 14;
# sam.rfLab.monitorPhy    = 1;     # USB adapter; onboard wlan0 is phy0
```

## Operate (from lenovo, in this repo's devenv)

| Task | What it does |
|------|--------------|
| `devenv tasks run rf:beacons` | Passive channel-hop beacon sweep → decoded AP table (SSID, channel, dBm, beacon count); pcap saved to `~/rf-lab-captures`. `RF_DWELL` sets per-channel dwell (default 1.2 s). |
| `RF_CHANNEL=6 devenv tasks run rf:capture` | Bounded monitor capture on one channel. `RF_SECONDS` (default 30), `RF_BSSID` to filter to one AP. |
| `devenv tasks run rf:btscan` | Passive Bluetooth/BLE device discovery. `RF_SECONDS` (default 15). |
| `devenv tasks run rf:list` | List captures on the Pi and locally. |

Analysis stays on lenovo: `nix shell nixpkgs#wireshark -c wireshark ~/rf-lab-captures/<file>.pcap`.

## On-Pi wrappers

The tasks call three narrow `sudo` wrappers (lukas has NOPASSWD for exactly
these, nothing else): `rf-sweep [dwell]`, `rf-capture <ch> [secs] [bpf]`,
`rf-btscan [secs]`. Each restores managed mode on exit and tolerates the USB
adapter's undervoltage drops; a wedged RX path triggers one module-reload
recovery, then asks for a physical replug.

## Hardware limits

2.4 GHz only (both radios); onboard `wlan0` cannot do monitor mode (USB adapter
only); Ethernet and the adapter share one USB 2.0 bus; onboard Bluetooth is
unreliable until the power supply is replaced. Details and the adapter's chipset
report: `~/knowledge/homelab/runbooks/naked-pi-rf-lab.md`.
