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

Both BIOS control and Linux PWM control clamp to a hardware minimum:

- Lowest observed `fan1_input`: ~`952 RPM`
- Even with manual PWM writes (`pwm1=0..40`) the fan stays ~`952 RPM`
- BIOS Smart Fan shows `pwm1_enable=2` (auto) but still keeps `pwm1≈32/255` at idle and `fan1≈952 RPM`

Conclusion: **“dead silent” idle is not achievable on this box purely via software**, unless the physical fan/cooler is replaced.

### Policy In This Repo

We default to **BIOS Smart Fan** on this host:

- `sam.profile.fancontrol = false` in `hosts/msi-ms7758/variables.nix`

We keep `hosts/msi-ms7758/fancontrol-worker.conf` in the repo for reference/testing, but do not enable `hardware.fancontrol` by default because it overrides firmware fan control.

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

If you temporarily want Linux to take over fan control:

```bash
sudo systemctl start fancontrol
```

and then disable again:

```bash
sudo systemctl stop fancontrol
```

### Practical Options To Reduce Noise

- Replace the CPU cooler/fan with a quieter one (bigger fan, lower minimum RPM).
- Clean dust and consider re-pasting (high idle temps will force higher fan duty).
- Disable OC/OC Genie and prefer ECO/balanced firmware settings.
- Case/PSU/GPU fans may still be audible; only fans connected to motherboard headers are controllable.

