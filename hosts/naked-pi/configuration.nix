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
  sam.rfLab.bluetooth.enable = true;

  # Pi 3 onboard radio is 2.4 GHz only; override the shared 5 GHz SSID. SSID is
  # public so it is fine in-repo; the PSK stays in sops.
  networking.networkmanager.ensureProfiles.profiles.home-wifi.wifi.ssid =
    lib.mkForce "Lilla Ettan 2.4";

  # Send the MAC as DHCP client-id so the router's MAC reservation (.138) applies;
  # a sticky client-id lease otherwise shadowed it. See vault: dhcp-reservations.md
  networking.networkmanager.ensureProfiles.profiles.home-wifi.ipv4.dhcp-client-id =
    lib.mkForce "mac";

  # age from the host SSH key WITHOUT sam.hostSecrets, so naked-pi decrypts only
  # secrets/homelab/wifi.yaml — not the operator tokens #32 keeps off this host.
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
