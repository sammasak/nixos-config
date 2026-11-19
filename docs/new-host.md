# Adding a new host

How a machine joins the fleet, written from onboarding `asus-b460m` (a
Windows desktop). A Linux-only machine skips the Windows parts. Pis have their
own image path (`modules/hardware/pi-sd-image.nix`).

Hard rules for a dual-boot machine: back up Windows and store the BitLocker
recovery key off the machine before any disk change; never format or
repartition the existing EFI system partition (ESP); never touch a Windows or
recovery partition; never use `modules/hardware/disko-single-ext4.nix` (it
takes the whole disk).

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
too few: import `modules/hardware/windows-dual-boot.nix` in the host's
`configuration.nix`, as msi and asus do (loader on the shared ESP mounted at `/boot`,
GRUB directory on root, hand-written Windows entry, os-prober off; it asserts that
`/boot` is a vfat mount). GRUB's loader takes under 1 MB of the ESP.

## 3. Windows-side preparation

In this order, nothing skipped:

1. Back up the Windows data (or take a full disk image) to another machine or
   drive, and confirm a file restores from it.
2. If BitLocker is on, store the recovery key off the machine
   (`manage-bde -protectors -get C:`, or the Microsoft account). Booting
   Windows through GRUB changes the measured boot path, so expect the recovery
   prompt at least once and have the key at hand.
3. Suspend BitLocker until it is resumed by hand:
   `Suspend-BitLocker -MountPoint C: -RebootCount 0`. The default resumes it
   after one reboot, and the steps below reboot before the shrink.
4. Turn off hibernation and Fast Startup, and keep the clock in UTC:

   ```
   powercfg /h off
   reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
   ```

5. Shrink C: with diskpart (`select volume C` / `shrink desired=<MB>`). The
   limit `querymax` reports is set by unmovable files, not by free space. To go
   past it, turn the pagefile off (`AutomaticManagedPagefile=False`, delete the
   `Win32_PageFileSetting`), turn System Restore off
   (`Disable-ComputerRestore -Drive C:\`) and delete the shadow copies
   (`vssadmin delete shadows /for=C: /all /quiet`; this destroys every restore
   point), reboot, query again, shrink.
6. Turn the pagefile back on (`AutomaticManagedPagefile=True`) and System
   Restore back on (`Enable-ComputerRestore -Drive C:\`).

Decide the final size before installing: space freed later lands in front of
the Linux partition.

## 4. Installer

Boot a NixOS ISO in UEFI mode (ASUS boards: F8). The graphical ISO does not
start sshd; in its terminal:

```
mkdir -p ~/.ssh && curl -fsSL https://github.com/sammasak.keys > ~/.ssh/authorized_keys
sudo systemctl start sshd
```

Every command in this step runs on the installer, never on lenovo (which has
an `nvme0n1` too): from lenovo, `ssh nixos@<installer-ip>` first. `<disk>`,
`<n>` and `<esp>` are placeholders: read them from this machine, do not copy
another host's.

Look before writing anything:

```
lsblk -f
sudo sgdisk -p /dev/<disk>
```

The ESP must be type `EF00` and already hold `EFI/Microsoft`
(`sudo mount -o ro /dev/<esp> /mnt && ls /mnt/EFI && sudo umount /mnt`).
The new partition goes in the free gap the shrink left (between the Windows
and recovery partitions), with `<first>`/`<last>` the exact sectors of that
gap and `<n>` the next unused number. Create it, then check that `/dev/<disk>p<n>`
is the new, empty partition of the expected size before `mkfs`:

```
sudo sgdisk -n <n>:<first>:<last> -t <n>:8304 -c <n>:nixos-root /dev/<disk>
lsblk -f /dev/<disk>
sudo mkfs.ext4 -L nixos /dev/<disk>p<n>
sudo mount /dev/<disk>p<n> /mnt          # by-label may lag udev
sudo mkdir -p /mnt/boot && sudo mount -o fmask=0077,dmask=0077 /dev/<esp> /mnt/boot   # the ESP, NOT formatted
```

Before GRUB writes to the ESP, save it and copy it off the machine. The ESP is
mounted root-only and `/mnt/root` does not exist yet, so every step is `sudo`, and
the copies land world-readable in `/tmp` for the `nixos` user to hand out:

```
sudo mkdir -p /mnt/root
sudo tar -C /mnt/boot -cf /mnt/root/esp-before-nixos.tar .
sudo efibootmgr -v | sudo tee /mnt/root/efibootmgr-before.txt >/dev/null
sudo install -m 0644 /mnt/root/esp-before-nixos.tar /mnt/root/efibootmgr-before.txt /tmp/
```

Then, from lenovo:

```
scp nixos@<installer-ip>:/tmp/{esp-before-nixos.tar,efibootmgr-before.txt} .
```

Run `nixos-generate-config --root /mnt`, replace `configuration.nix` with a
bootstrap (an import of `windows-dual-boot.nix`, scp'd next to it from a checkout, as the
module needs nothing else from the repo; `networking.hostName`, user `lukas` with lenovo's
key, sshd key-only, flakes), then `nixos-install --no-root-passwd`. At the machine,
boot both GRUB entries: NixOS, and Windows to the desktop. A missing
`kvm-intel` in the hardware scan means VT-x is off in the firmware.

## 5. Register it (one PR)

Only once both systems boot. Per `CLAUDE.md` "Adding a New Host", plus:

- the fingerprint read on the console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`),
  never `ssh-keyscan` (`docs/ssh-host-keys.md`);
- `ssh-to-age` of the same key as the recipient of exactly the files the host
  declares secrets from (`nixos:known-hosts-test` fails a needless one), then
  `sops updatekeys -y` on each;
- `scripts/test-ssh-known-hosts.py`: `EXPECTED`, `SOPS_RECIPIENTS`, the hard-coded host set;
- the hand-kept host lists (#480). Caddy's OTLP allowlist (`modules/homelab/edge.nix`) and alloy-otlp's
  `host.name` allowlist (`modules/homelab/monitoring/alloy-otlp.nix`) are derived from the fleet; these fail
  `nixos:known-hosts-test` until the host is added:
  - the host rows in `docs/architecture.md`, CLAUDE.md's deploy block and hostnames;
- the host rows in `README.md` and the fleet size the docs state (`nixos:readability-test`);
- not checked yet: the hosts `scripts/test-alloy-otlp-sanitizer.sh` feeds the relabel;
- for a host with the `runtime-host` role:
  - its store-cache key in `modules/core/store-cache.nix`: the role enables `sam.storeCache`, and evaluation fails
    while the host has no key there. Generate it on the host first, in a root shell (`sudo -i`), with the commands of
    the `store-cache-key` unit (which then skips: `ConditionPathExists=!.../secret-key`), and copy `public-key`:

    ```sh
    install -d -m 0755 /var/lib/store-cache && cd /var/lib/store-cache && umask 077
    nix --extra-experimental-features nix-command key generate-secret --key-name <hostName>-store-1 > secret-key.new &&
      nix --extra-experimental-features nix-command key convert-secret-to-public < secret-key.new > public-key &&
      chmod 0644 public-key && mv secret-key.new secret-key
    ```

  - its name in `storeCaches` in `modules/core/fleet.nix`, the listener that admits the other fleet hosts to its
    port 5000: `modules/core/store-cache.nix` fails evaluation while it and `sam.storeCache` disagree;
  - its `sam.herdr.machines` entry and `sam.workers.jumpHosts` name on lenovo: lenovo's evaluation fails while they
    differ from the runtime hosts of `flake-modules/hosts.nix` (and on a host's removal there until they drop it);
  - the `docs/nspawn-workers.md` row (`nixos:known-hosts-test`), its pool columns "not measured yet" until
    step 7 sizes `sam.workers`;
- for a host that is not always up (scheduled power-off, dual boot), `sleeps = true`
  on its `modules/core/fleet.nix` entry. That one fact keeps it out of every store
  cache's substituters and moves it from `NodeChronicNotReady` to `HostExpectedOff`;
  no rule edit. With a `power` window it is planned off only outside that window
  (`homelab:node:planned_off`, rendered from the fleet by `modules/homelab/monitoring/rules/homelab.nix`).
- for a work-hours window, `power = { mac; interface; wake; off; }` on the same entry: lenovo
  wakes it, and it arms Wake-on-LAN on `interface` (`wol-<interface>`) and powers itself off
  (`modules/core/power-schedule.nix`). Evaluation fails unless it also has `sleeps = true`. Add
  `power.manualOff = true` when the owner also powers it off by hand (asus-b460m): the alerts then expect it
  off at any time, not only outside its window.

Commit and gate on a worker (msi or acer), not lenovo.

## 6. First switch

The deploy user exists only after the first fleet switch, and
`mutableUsers = true` keeps passwords out of the config: set `lukas`'s password
first (`sudo passwd lukas` over an `ssh -t` session; the fleet config drops the
bootstrap's passwordless sudo). Then, building on the new host:

1. The host has no GitHub key and some inputs are private: from lenovo, copy
   every input into its store (sources only, no evaluation). Until lenovo runs
   the registration commit, its `known_hosts` lacks the new host, so point ssh
   at a file holding the host key read on the console
   (`<address> ssh-ed25519 <key>`):
   `NIX_SSHOPTS="-o UserKnownHostsFile=<file> -o StrictHostKeyChecking=yes" nix flake archive --no-check-sigs --to ssh-ng://lukas@<address> .`
2. Put the commit on the host (`git bundle` from the gate host, `git fetch` it into a clone).
3. Build as `lukas` and activate as root, in a `systemd-run` unit so a dropped
   ssh session does not kill it (root refuses a git tree owned by `lukas`):
   `nix build --no-link --print-out-paths .#nixosConfigurations.<name>.config.system.build.toplevel`,
   then as root `nix-env -p /nix/var/nix/profiles/system --set <out>` and
   `<out>/bin/switch-to-configuration switch`.
4. Reboot once: the switch from the bootstrap's `dbus` to the fleet's
   `dbus-broker` fails to reload on a live system and leaves it degraded until then.
5. The switch rewrote GRUB with the fleet config: at the machine, boot both
   entries again. Windows must reach the desktop; then resume BitLocker
   (`Resume-BitLocker -MountPoint C:`) and reboot Windows once more to confirm
   it starts without the recovery prompt.

Only after that, `just deploy <name>` from lenovo, and step 7.

## 7. Make it a worker (second PR)

`sam.workers` (`docs/nspawn-workers.md`), and its fleet `power` window if it sleeps, which arms Wake-on-LAN (the
role, its store-cache key and lenovo's `sam.herdr.machines` and `sam.workers.jumpHosts` came with step 5).
