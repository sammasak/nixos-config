{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/video/${vars.videoDriver}.nix
  ];

  sam.profile = vars;

  # Keep this host manual until the existing Windows/EFI layout is verified.
  system.autoUpgrade.enable = lib.mkForce false;
  system.autoUpgrade.allowReboot = lib.mkForce false;

  # The existing Windows ESP is small. Keep GRUB's mutable directory on root,
  # while leaving only the EFI loader on /boot.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;
    configurationLimit = 5;
    mirroredBoots = lib.mkForce [
      {
        path = "/boot-nix";
        efiSysMountPoint = "/boot";
        devices = [ "nodev" ];
      }
    ];
    extraEntries = ''
      menuentry "Windows Boot Manager" {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };

  networking.interfaces.enp3s0.wakeOnLan.enable = true;
  systemd.services.wol-enp3s0 = {
    description = "Enable Wake on LAN for enp3s0";
    after = [ "network-addresses-enp3s0.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s enp3s0 wol g";
    };
  };

  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # Initial onboarding is deliberately outside the cluster and SOPS tree. Add
  # the machine's verified SSH host key to SOPS before enabling k3s secrets.
  homelab.k3s.enable = lib.mkForce false;
}
