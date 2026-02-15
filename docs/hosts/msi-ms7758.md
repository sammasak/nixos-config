# `msi-ms7758` (MSI MS-7758 / Z77A-G43)

Legacy desktop tower running NixOS as a **headless k3s worker**. This host is used as a
best-effort GPU inference node (legacy NVIDIA Kepler) and a generic worker for the homelab.
Windows remains the gaming OS on this machine (dual-boot via GRUB).

## Boot

- Shared Windows ESP is mounted at `/boot` (VFAT).
- ESP size is very small (~100 MiB). We **do not** copy kernels/initrds into `/boot`
  on this host (`boot.loader.grub.copyKernels = false`), otherwise `/boot` fills up
  and `nixos-rebuild switch` fails.
- GRUB theme is provided via Stylix (matches the other hosts).
- The GRUB menu includes a `Windows Boot Manager` chainloader entry.

### Cleaning `/boot` Safely (Do Not Break Windows)

Rules:

- Never delete anything under `/boot/EFI/Microsoft`.
- Prefer deleting only NixOS-generated kernel copies under `/boot/kernels` (legacy from before `copyKernels=false`).

After a successful rebuild with `copyKernels=false`, confirm GRUB is no longer using `/boot/kernels`:

```bash
sudo rg -n "/boot/kernels" /boot/grub/grub.cfg || echo "ok: GRUB not using /boot/kernels"
```

Then you can remove the old copies:

```bash
sudo rm -rf /boot/kernels
sudo df -h /boot
```

## GPU

- GPU: NVIDIA Kepler (GeForce GTX 680, `10de:1180`)
- Driver: legacy 470xx series (for example `470.256.02`)

Notes:

- This generation is problematic for modern Wayland compositors and is not a target for Hyprland on this host.
- Many modern CUDA containers and inference stacks assume newer drivers and newer GPU compute capability. Treat this node as “legacy GPU / maybe Vulkan” and expect trial-and-error.
- Ollama's NVIDIA backend generally won't work on Kepler/470xx; plan for CPU or Vulkan backends.

## Kubernetes GPU Prereqs

We aim for a Kubernetes-friendly setup where the OS provides:

- NVIDIA drivers
- NVIDIA Container Toolkit CDI spec generation
- containerd (k3s) configured with CDI enabled
- a node label for scheduling (`gpu=nvidia`)

This repo configures CDI for k3s via `services.k3s.containerdConfigTemplate` and enables
`hardware.nvidia-container-toolkit` so `/var/run/cdi/nvidia-container-toolkit.json` is generated at boot.

Cluster-side components (to be done in `homelab-gitops`):

- Deploy NVIDIA device plugin (DaemonSet), preferably in a CDI-aware mode (`cdi-annotations`).
- Schedule inference workloads to this node via `nodeSelector: { gpu: nvidia }`.

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

WoL is intentionally not managed by NixOS for this host (the dual-boot setup is sensitive).
If you enable it manually, you may need firmware options enabled:

- “Wake on PCI-E” / “Resume by PCI-E device” (naming varies by BIOS)
- Disable “ErP” / “EuP” / “Deep Sleep” options that cut power to PCI-E in soft-off (naming varies)

Verify on the host (after installing `ethtool` if needed):

```bash
sudo ethtool enp3s0 | grep -Ei 'supports wake-on|wake-on'
```

## Scheduled Power Off/On

This host supports an **optional** RTC-wake based schedule:

- At a configured time, the system runs `rtcwake -m off ...`, which both powers off and programs the next wake alarm.
- This requires motherboard support for RTC wake from soft-off (S5) and may require enabling BIOS options.

Not managed by NixOS for this host.
