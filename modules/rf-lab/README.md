# rf-lab: naked-pi 2.4 GHz RF lab

Opt-in 2.4 GHz tooling for the `naked-pi` host (Raspberry Pi 3, role `rf-lab`):
passive capture and discovery, plus the owned-AP lab (`ap.nix`) and the
Ethernet-gated HIL kick test (`hil.nix`) as the only deauth/AP-mode paths, all
scoped to our own AP and enrolled stations. No frame injection, jamming or
action against anyone else's network. Operated from lenovo over SSH.

## Enable

Set in a host's config (the `rf-lab` role does this):

```nix
sam.rfLab.enable = true;          # installs the kit + narrow sudo
```

Captures land in `/var/lib/rf-lab/captures` on the Pi and age out after 14 days.

## Operate (from lenovo, in this repo's devenv)

| Task | What it does |
|------|--------------|
| `devenv tasks run rf:beacons` | Passive channel-hop beacon sweep → decoded AP table (SSID, channel, dBm, beacon count); pcap saved to `~/rf-lab-captures`. `RF_DWELL` sets per-channel dwell (default 1.2 s). |
| `RF_CHANNEL=6 devenv tasks run rf:capture` | Bounded monitor capture on one channel. `RF_SECONDS` (default 30), `RF_BSSID` to filter to one AP. |
| `devenv tasks run rf:btscan` | Passive Bluetooth/BLE device discovery. `RF_SECONDS` (default 15). |
| `devenv tasks run rf:list` | List captures on the Pi and locally. |
| `devenv tasks run rf:analyze` | Offline analysis of a pcap (`RF_PCAP`, default newest local): management-frame breakdown and any deauth/disassoc reason codes. |
| `devenv tasks run rf:analyze-test` | Offline, deterministic: run the `rf:analyze` decode over the crafted fixtures in `fixtures/` and assert beacon count + deauth/disassoc reason codes. No device. |
| `devenv tasks run rf:sim` | Fully-virtual `mac80211_hwsim` lab (two netns): real hostapd+wpa_supplicant association, an iperf3 throughput measurement over the virtual link, optional `tc-netem` packet loss (`RF_LOSS` percent), and a disconnect/reconnect recovery (`RF_OUTAGE` seconds). Emits a JSON artifact; no physical radio. |

## Crafted pcap fixtures

`fixtures/` holds tiny **synthetic** beacon / deauth / disassoc pcaps built offline
with scapy (`fixtures/craft-fixtures.py`) — not hardware captures, never
transmitted. `rf:analyze-test` asserts the decode logic recognises them. See
`fixtures/README.md`.

## hwsim data-plane VM test (#40 kernel-blocker check)

`nix build .#packages.x86_64-linux.rf-hwsim-dataplane -L` runs
`tests/rf-hwsim-dataplane.nix` in a QEMU VM. Finding: the data-plane block is
the wmediumd/netns setup of `rf-sim`, not the Pi's kernel 7.2.9.

Analysis stays on lenovo: `nix shell nixpkgs#wireshark -c wireshark ~/rf-lab-captures/<file>.pcap`.

## Owned-AP lab (opt-in, off by default)

An isolated WPA2 test AP on the onboard `wlan0`, for associating **your own**
clients — never a tool against anyone else's network. No bridge/NAT/route to the
LAN, so lab clients cannot reach the management subnet; the AP never touches the
Ethernet management path. Off by default (inert); enable per host:

```nix
sam.rfLab.ap = {
  enable = true;
  pskFile = config.sops.secrets."rf-lab/psk".path;  # WPA2 passphrase, one line
  # ssid = "naked-lab"; channel = 6; gateway = "10.77.0.1";
};
```

`hostapd` (WPA2) + `dnsmasq` (DHCP only, `10.77.0.0/24`) run as explicit systemd
units; the passphrase is loaded as a systemd credential, never in the Nix store.
Verified on naked-pi: hostapd reaches `AP-ENABLED` on `wlan0` and Ethernet SSH is
unaffected. Associating a client is a physical step (bring your own device).

## Two-radio hardware-in-the-loop kick test (#38)

`rf-ap-kick-hil` (task `rf:ap-kick-hil`) proves the `rf-ap-kick` deauth primitive
on **real radios**: onboard `wlan0` as a throwaway WPA2 AP, the USB adapter
(rtl8192cu) as an enrolled station, one `hostapd_cli deauthenticate`, and a timed
reassociation — emitting `{"kind":"hardware",...}`. It is the only path to #38's
real over-the-air acceptance without an external client.

It **hard-refuses unless the default route is a third interface (Ethernet)**, so
it structurally cannot cut SSH the way bringing the AP up on `wlan0` would; the
onboard radio supports `AP` and the USB phy supports `managed`, on separate phys,
so concurrent AP+station is within the hardware's limits (`iw phy` confirmed). An
`EXIT` trap tears down hostapd/wpa_supplicant and hands `wlan0` back to
NetworkManager. Run `rf:ap-kick-hil` for a dry-run (prints the gate decision);
`RF_HIL_COMMIT=1 rf:ap-kick-hil` runs the real test. **Only run with Ethernet
plugged in** — otherwise it refuses by design. The rtl8192cu RX path is fragile
under mode flips/undervoltage, so a non-association is a retry/replug, not a
failure of the primitive.

## On-Pi wrappers

The tasks call narrow `sudo` wrappers (lukas has NOPASSWD for exactly these,
nothing else): the `tools` list in `default.nix`, plus those `ap.nix`,
`hil.nix` and `bluetooth.nix` add when enabled. The monitor-mode ones restore
managed mode on exit and tolerate the USB adapter's undervoltage drops; a wedged
RX path triggers one module-reload recovery, then asks for a physical replug.

## Hardware limits

2.4 GHz only (both radios); onboard `wlan0` cannot do monitor mode (USB adapter
only); Ethernet and the adapter share one USB 2.0 bus; onboard Bluetooth is
unreliable until the power supply is replaced. Details and the adapter's chipset
report: `~/knowledge/homelab/runbooks/naked-pi-rf-lab.md`.
