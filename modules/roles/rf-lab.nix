# Headless Wi-Fi learning appliance on a 1 GiB board: Ethernet is the only
# management path, every Wi-Fi radio is left to manual capture work.
{ config, lib, pkgs, ... }:
let
  username = config.sam.profile.username;
in
{
  imports = [
    ./base.nix
    ../homelab/deploy-target.nix
    ../rf-lab
  ];

  sam.rfLab.enable = true;

  # NM would otherwise autoconnect or rescan a radio mid-capture; Ethernet stays managed.
  networking.networkmanager.unmanaged = [ "type:wifi" ];
  systemd.services.ModemManager.enable = lib.mkForce false;

  hardware.wirelessRegulatoryDatabase = true;
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=SE
  '';

  # A Nix trusted-user is root-equivalent; deploy-rs becomes root via sudo instead.
  nix.settings.trusted-users = lib.mkForce [ "root" ];
  # 1 GiB: two parallel compiles OOM the board. Deploys substitute; builds are the exception.
  nix.settings = {
    max-jobs = 1;
    cores = 1;
  };
  nix.gc.dates = lib.mkForce "weekly";
  nix.gc.options = lib.mkForce "--delete-older-than 7d";
  nix.settings.min-free = 2 * 1024 * 1024 * 1024;
  services.journald.settings.Journal.SystemMaxUse = lib.mkForce "100M";

  # Headless: its Home Manager themes compile sass and libxml2 on the Pi (aarch64 cache misses).
  stylix.enable = lib.mkForce false;
  home-manager.users.${username}.fonts.fontconfig.enable = lib.mkForce false;

  # An unattended upgrade would compile cache misses on the SD card and reboot the board.
  system.autoUpgrade.enable = lib.mkForce false;
}
