# Adding a new host

The steps that brought `asus-b460m` (a Windows desktop) into the fleet on
2026-11-16, written so the next machine can follow them. A Linux-only machine
skips the Windows parts. Pis have their own image path (`modules/hardware/pi-sd-image.nix`).

Hard rules for a dual-boot machine: never format or repartition the existing
EFI system partition (ESP), never touch a Windows or recovery partition, and
never use `modules/hardware/disko-single-ext4.nix` (it takes the whole disk).

## 1. Reach it and inspect it, read-only

On Windows, in PowerShell as Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic
Add-Content C:\ProgramData\ssh\administrators_authorized_keys '<lenovo ~/.ssh/id_ed25519.pub>'
icacls.exe C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
```

If `Start-Service sshd` finds no service while the capability reads
`Installed`, reboot once. The firewall rule only applies on a Private network.

Over SSH: `Get-Partition` and the Storage module return nothing in a non-interactive
session; read the layout with `Get-CimInstance Win32_DiskPartition` and
`Win32_Volume`, and the shrink limit with a diskpart script
(`select volume C` / `shrink querymax`). Pipe longer PowerShell as a file
(`scp`, then `powershell -File`); `-Command -` on stdin truncates.

Record: firmware mode, Secure Boot, BitLocker, Fast Startup, disks and free
space, ESP size and free space, CPU, RAM, GPU, NIC, MAC, Wake-on-LAN.

## 2. Bootloader choice

systemd-boot (the fleet default, `modules/core/boot.nix`) copies every
generation's kernel and initrd onto the ESP. A Windows ESP of 100-260 MB holds
too few: use the GRUB pattern from `hosts/msi-ms7758` and `hosts/asus-b460m`
(loader on the shared ESP, GRUB directory on root, hand-written Windows entry,
os-prober off). GRUB's loader takes under 1 MB of the ESP.

## 3. Windows-side preparation

```
powercfg /h off
reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

Suspend BitLocker first if it is on (and save the recovery key). Shrink C:
with diskpart (`select volume C` / `shrink desired=<MB>`). The limit
`querymax` reports is set by unmovable files, not by free space; to go past
it, turn the pagefile off (`AutomaticManagedPagefile=False`, delete the
`Win32_PageFileSetting`), turn System Restore off and delete shadow copies
(`vssadmin delete shadows /for=C: /all /quiet`), reboot, query again, shrink,
then turn the pagefile back on. Decide the final size before installing:
space freed later lands in front of the Linux partition.

## 4. Installer

Boot a NixOS ISO in UEFI mode (ASUS boards: F8). The graphical ISO does not
start sshd; in its terminal:

```
mkdir -p ~/.ssh && curl -fsSL https://github.com/sammasak.keys > ~/.ssh/authorized_keys
sudo systemctl start sshd
```

From lenovo, with exact sectors read from `sgdisk -p` (the gap between the
Windows and recovery partitions):

```
sudo sgdisk -n 5:<first>:<last> -t 5:8304 -c 5:nixos-root /dev/nvme0n1
sudo mkfs.ext4 -L nixos /dev/nvme0n1p5
sudo mount /dev/nvme0n1p5 /mnt          # by-label may lag udev
sudo mkdir -p /mnt/boot && sudo mount -o fmask=0077,dmask=0077 /dev/nvme0n1p1 /mnt/boot   # the ESP, NOT formatted
```

Before GRUB writes to the ESP, save it: `tar -C /mnt/boot -cf /mnt/root/esp-before-nixos.tar .`
and `efibootmgr -v > /mnt/root/efibootmgr-before.txt`.
`nixos-generate-config --root /mnt`, replace `configuration.nix` with a
bootstrap (the GRUB block, `networking.hostName`, user `lukas` with lenovo's
key, sshd key-only, flakes), `nixos-install --no-root-passwd`. Check both
GRUB entries boot at the machine. A missing `kvm-intel` in the hardware scan
means VT-x is off in the firmware.

## 5. Register it (one PR)

Per `CLAUDE.md` "Adding a New Host", plus:

- the fingerprint read on the console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`),
  never `ssh-keyscan` (`docs/ssh-host-keys.md`);
- `ssh-to-age` of the same key as the recipient of exactly the files the host
  declares secrets from (`nixos:known-hosts-test` fails a needless one), then
  `sops updatekeys -y` on each;
- `scripts/test-ssh-known-hosts.py`: `EXPECTED`, `SOPS_RECIPIENTS`, the hard-coded host set;
- the `just deploy` and `just dry-activate` HOST patterns.

Commit and gate on a worker (msi or acer), not lenovo.

## 6. First switch

The deploy user exists only after the first fleet switch, and
`mutableUsers = true` keeps passwords out of the config: set `lukas`'s password
first (`sudo passwd lukas` over an `ssh -t` session; the fleet config drops the
bootstrap's passwordless sudo). Then, building on the new host:

1. The host has no GitHub key and some inputs are private: from lenovo, copy
   every input into its store (sources only, no evaluation):
   `NIX_SSHOPTS=... nix flake archive --no-check-sigs --to ssh-ng://lukas@<address> .`
2. Put the commit on the host (`git bundle` from the gate host, `git fetch` it into a clone).
3. Build as `lukas` and activate as root, in a `systemd-run` unit so a dropped
   ssh session does not kill it (root refuses a git tree owned by `lukas`):
   `nix build --no-link --print-out-paths .#nixosConfigurations.<name>.config.system.build.toplevel`,
   then as root `nix-env -p /nix/var/nix/profiles/system --set <out>` and
   `<out>/bin/switch-to-configuration switch`.
4. Reboot once: the switch from the bootstrap's `dbus` to the fleet's
   `dbus-broker` fails to reload on a live system and leaves it degraded until then.

After that, `just deploy <name>` from lenovo.

## 7. Make it a worker (second PR)

Its store-cache key (`modules/core/store-cache.nix`; harmonia is socket-activated, so
the key exists only after a first request: `curl http://127.0.0.1:5000/nix-cache-info`,
then `cat /var/lib/store-cache/public-key`), `sam.workers` (`docs/nspawn-workers.md`), `sam.herdr.machines` and
`sam.workers.jumpHosts` on lenovo, Wake-on-LAN and a power window if it sleeps.
