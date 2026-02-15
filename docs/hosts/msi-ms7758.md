# `msi-ms7758` (MSI MS-7758 / Z77A-G43)

Legacy desktop tower running NixOS as a **headless k3s worker** with a legacy NVIDIA GPU used for local inference (Ollama).
Windows remains the primary gaming OS on this machine (dual-boot via GRUB).

## Boot

- Shared Windows ESP is mounted at `/boot` (VFAT).
- GRUB theme is provided via Stylix (matches the other hosts).
- The GRUB menu includes a `Windows Boot Manager` chainloader entry.

## GPU

- GPU: NVIDIA Kepler (GeForce GTX 680, `10de:1180`)
- Driver: legacy 470xx series (for example `470.256.02`)

This generation is problematic for modern Wayland compositors and is not a target for Hyprland on this host.

## Fan Control (Important)

This motherboard exposes fan/PWM via the Fintek Super I/O:

- Kernel modules: `f71882fg`, `lm78`
- `sensors` shows a `f71869a-isa-0290` device with `fan1_input` + `pwm1`.

### Verified Behavior

We tried both BIOS Smart Fan and Linux `fancontrol` (manual PWM), and both clamp
to a hardware minimum:

- Lowest observed `fan1_input`: ~`952 RPM`
- Even with manual PWM writes (`pwm1=0..40`), the fan stays ~`952 RPM`
- BIOS Smart Fan (`pwm1_enable=2`) still keeps `pwm1≈32/255` at idle and `fan1≈952 RPM`

Conclusion: **“dead silent” idle is not achievable on this box purely via software**, unless the physical fan/cooler is replaced.

### Policy In This Repo

We default to **BIOS Smart Fan** on this host and do not ship a `fancontrol.service`:

- `sam.profile.fancontrol = false` in `hosts/msi-ms7758/variables.nix`

### How To Re-Test

Show current mode and fan floor:

```bash
base=/sys/class/hwmon/hwmon0/device
cpu=/sys/class/hwmon/hwmon2
for i in {1..20}; do
  ts=$(date +%H:%M:%S)
  echo "$ts pwm1_enable=$(cat $base/pwm1_enable) pwm1=$(cat $base/pwm1) fan1=$(cat $base/fan1_input) cpu_pkg=$(( $(cat $cpu/temp1_input)/1000 ))C"
  sleep 2
done
```

Note: this host intentionally does **not** enable Linux `fancontrol` (we rely on
BIOS Smart Fan). There is no `fancontrol.service` shipped by this configuration.

### Practical Options To Reduce Noise

- Replace the CPU cooler/fan with a quieter one (bigger fan, lower minimum RPM).
- Clean dust and consider re-pasting (high idle temps will force higher fan duty).
- Disable OC/OC Genie and prefer ECO/balanced firmware settings.
- Case/PSU/GPU fans may still be audible; only fans connected to motherboard headers are controllable.

## Wake-on-LAN (WoL)

- Interface: `enp3s0`
- MAC: `d4:3d:7e:4a:f9:3d`

The system enables WoL via `ethtool` at boot. You may also need firmware options enabled:

- “Wake on PCI-E” / “Resume by PCI-E device” (naming varies by BIOS)
- Disable “ErP” / “EuP” / “Deep Sleep” options that cut power to PCI-E in soft-off (naming varies)

Verify on the host:

```bash
sudo ethtool enp3s0 | grep -Ei 'supports wake-on|wake-on'
```

## Scheduled Power Off/On

This host supports an **optional** RTC-wake based schedule:

- At a configured time, the system runs `rtcwake -m off ...`, which both powers off and programs the next wake alarm.
- This requires motherboard support for RTC wake from soft-off (S5) and may require enabling BIOS options.

Configuration lives in `hosts/msi-ms7758/configuration.nix` under `autoPower`.
