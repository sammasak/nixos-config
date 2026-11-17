#!/usr/bin/env python3
"""The dual-boot towers' GRUB (modules/hardware/windows-dual-boot.nix) as msi-ms7758 and asus-b460m render it: GRUB on,
systemd-boot off, the loader on the /boot ESP with its directory on root, and the Windows entry chainloading
bootmgfw.efi; no other host imports it. Its assertion refuses an efiSysMountPoint that is not a vfat filesystem in
fileSystems (seeded: msi's /boot as ext4, asus's loader pointed at an /efi that is not mounted)."""

import gate_probe
from gate_probe import check, finish



P = gate_probe.section("dual-boot")
grub, F = P["grub"], P["failing"]
towers = {"msi-ms7758", "asus-b460m"}
for host, g in grub.items():
    if host in towers:
        entry = g["extraEntries"]
        check(g["enable"] and not g["systemdBoot"]
              and [(b["path"], b["efiSysMountPoint"]) for b in g["mirroredBoots"]] == [("/boot-nix", "/boot")],
              f"{host}: GRUB, not systemd-boot, its loader on the /boot ESP and its directory on /boot-nix")
        check('menuentry "Windows Boot Manager"' in entry
              and "search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi" in entry
              and "chainloader /EFI/Microsoft/Boot/bootmgfw.efi" in entry,
              f"{host}: the Windows entry chainloads bootmgfw.efi")
    else:
        check("Windows Boot Manager" not in g["extraEntries"], f"{host} has no Windows entry")

esp = [m for h in ("msi", "asus") for m in F[h] if "windows-dual-boot" in m]
check(esp == [], f"msi and asus fail no dual-boot assertion ({esp})")
check(any("efiSysMountPoint /boot is not a vfat filesystem" in m for m in F["notVfat"]),
      f"seeded: msi's /boot as ext4 fails ({F['notVfat']})")
check(any("efiSysMountPoint /efi is not a vfat filesystem" in m for m in F["noMount"]),
      f"seeded: asus's loader on an unmounted /efi fails ({F['noMount']})")

finish()
