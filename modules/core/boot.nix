{ pkgs, lib, ... }:
{
  boot = {
    supportedFilesystems = [
      "ntfs"
      "exfat"
      "ext4"
      "fat32"
      "btrfs"
    ];
    tmp.cleanOnBoot = true;
    # Latest over LTS — revisit if the Cilium eBPF path breaks.
    # See vault: homelab/decisions/ADR-025-linux-kernel-latest-over-lts.md
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernelParams = [
      "preempt=full"
    ];
    loader = {
      # Default: manage NVRAM boot entries. Some environments (legacy/CSM boot,
      # restricted firmware) can't access EFI variables, so allow host override.
      efi.canTouchEfiVariables = lib.mkDefault true;
      # Default ESP mountpoint. Some hosts mount ESP at /boot/efi to keep /boot on
      # the root filesystem (useful when sharing a small Windows ESP).
      efi.efiSysMountPoint = lib.mkDefault "/boot";
      timeout = 3;
      # No GRUB anywhere: systemd-boot has no core/module split to fall out of
      # lockstep on a bootloader bump (the skew that bricked lenovo's boot).
      systemd-boot = {
        enable = true;
        configurationLimit = 4;
      };
    };
    binfmt.registrations.appimage = {
      wrapInterpreterInShell = false;
      interpreter = "${pkgs.appimage-run}/bin/appimage-run";
      recognitionType = "magic";
      offset = 0;
      mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
      magicOrExtension = ''\x7fELF....AI\x02'';
    };
  };
}
