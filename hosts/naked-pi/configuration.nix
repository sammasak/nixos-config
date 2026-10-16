{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/sd-image-root-lock.nix

    # Onboard wlan0 as a management fallback over home Wi-Fi when Ethernet is
    # unplugged; the USB capture adapter stays NM-unmanaged (rf-lab role).
    ../../modules/core/wifi.nix
  ];

  sam.profile = vars;
  sam.wifi.declarativeHomeProfile = true;

  # sops-nix age straight from the host SSH key — WITHOUT sam.hostSecrets, which
  # would also pull the Claude/nix operator tokens naked-pi is not a recipient of
  # (and #32 keeps off this host). naked-pi decrypts only secrets/homelab/wifi.yaml.
  sops.age = {
    sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    keyFile = "/var/lib/sops-nix/key.txt";
    generateKey = true;
  };

  # No UEFI: the Pi firmware chains U-Boot, which reads /boot/extlinux.
  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_3
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 4;
}
