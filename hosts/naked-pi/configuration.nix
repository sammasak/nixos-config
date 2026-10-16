{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/sd-image-root-lock.nix
    # Onboard wlan0 management fallback over home Wi-Fi. Vault:
    # ~/knowledge/homelab/runbooks/naked-pi-rf-lab.md
    ../../modules/core/wifi.nix
  ];

  sam.profile = vars;
  sam.wifi.declarativeHomeProfile = true;

  # Pi 3 onboard radio is 2.4 GHz only, so override the shared 5 GHz SSID.
  networking.networkmanager.ensureProfiles.profiles.home-wifi.wifi.ssid =
    lib.mkForce "Lilla Ettan 2.4";

  # Static Wi-Fi IP (outside the DHCP pool): the router won't honour a reservation
  # on an in-use in-pool IP. See vault: naked-pi-rf-lab.md, dhcp-reservations.md.
  networking.networkmanager.ensureProfiles.profiles.home-wifi.ipv4 = lib.mkForce {
    method = "manual";
    address1 = "192.168.10.60/24,192.168.10.1";
    dns = "192.168.10.1";
  };

  # age from the host SSH key WITHOUT sam.hostSecrets, so naked-pi decrypts only
  # secrets/homelab/wifi.yaml, not the operator tokens #32 keeps off this host.
  sops.age = {
    sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    keyFile = "/var/lib/sops-nix/key.txt";
    generateKey = true;
  };

  # https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_3
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 4;
}
