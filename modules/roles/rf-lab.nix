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

  # Keep USB capture adapters (wlu*) out of NM so a capture can't be interrupted
  # or interfere; the onboard wlan0 stays managed so the host can use declarative
  # home Wi-Fi for management when Ethernet is unplugged.
  networking.networkmanager.unmanaged = [ "interface-name:wlu*" ];
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

  # A config that breaks one of these is fixed by walking to the board.
  assertions =
    let
      ssh = config.services.openssh;
      watchdog = config.sam.rfLab.netWatchdog;
      names = map (p: lib.toLower (p.pname or p.name or ""));
      declared = names config.environment.systemPackages
        ++ lib.concatMap (u: names u.packages) (lib.attrValues config.users.users)
        ++ lib.concatMap (u: names u.home.packages) (lib.attrValues config.home-manager.users);
      # REA and the tools it drives belong on the analysis workstation (#42 "Architectural boundaries").
      heavy = builtins.filter (n: builtins.match ".*(ghidra|binwalk|unblob|jadx|nodejs|npm|rea-agents|radare2|rizin).*" n != null) declared;
    in
    [
      {
        assertion = ssh.enable && ssh.settings.PasswordAuthentication == false && ssh.settings.PermitRootLogin == "no";
        message = "role rf-lab: key-only SSH is the board's management path; keep sshd on with PasswordAuthentication = false and PermitRootLogin = \"no\" (modules/core/services.nix).";
      }
      {
        assertion = !ssh.openFirewall && config.networking.firewall.enable;
        message = "role rf-lab: SSH is scoped to the LAN by the firewall rule in modules/core/network.nix; keep networking.firewall.enable = true and services.openssh.openFirewall = false.";
      }
      {
        assertion = watchdog.enable && config.networking.networkmanager.ensureProfiles.profiles ? ${watchdog.recoveryProfile};
        message = "role rf-lab: the management fallback needs sam.rfLab.netWatchdog.enable and the NetworkManager profile it recovers (\"${watchdog.recoveryProfile}\"; sam.wifi.declarativeHomeProfile = true declares home-wifi).";
      }
      {
        assertion = config.system.activationScripts ? lockEmptyRootPassword;
        message = "role rf-lab: the SD image ships root with an empty password; import modules/hardware/sd-image-root-lock.nix in the host.";
      }
      {
        assertion = !config.services.k3s.enable;
        message = "role rf-lab: the 1 GiB board is not a k3s node; drop services.k3s (the homelab-agent role) from this host.";
      }
      {
        assertion = heavy == [ ];
        message = "role rf-lab: heavyweight reverse-engineering tooling belongs on the analysis workstation, not the 1 GiB board; remove ${lib.concatStringsSep ", " heavy} from environment.systemPackages, users.users.<name>.packages or home.packages.";
      }
    ];
}
