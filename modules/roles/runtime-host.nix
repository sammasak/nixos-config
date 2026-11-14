# Headless worker host (msi-ms7758, acer-swift): runs the ephemeral nspawn workers (modules/workers),
# pushed by deploy-rs, unthemed, and with maintenance that stays out of a boot.
{ config, lib, ... }:
let
  desktop = config.sam.desktop.enable;
in
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/deploy-target.nix
  ];

  # Delivers nix_access_token, and claude_oauth_token when the host has devTools or a claude worker.
  sam.hostSecrets.enable = true;

  # What an environment builds here, the other hosts download (modules/core/store-cache.nix).
  sam.storeCache.enable = true;

  # The relay and environments' telemetry only: host sessions keep their Claude settings (docs/native-otel-canary.md).
  sam.claude.telemetry.enable = false;

  # An agent that is talked into it reaches the internet, not the LAN, the cluster or this host (DNS excepted).
  services.devEnvironments.blockedNetworks = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
  ];

  # A guest may override max-jobs and cores per build, so CPUQuota holds the 2 x 2 bound; MemoryMax fails a build, never k3s.
  nix.settings = {
    max-jobs = 2;
    cores = 2;
    min-free = lib.mkDefault (15 * 1024 * 1024 * 1024);
    max-free = lib.mkDefault (40 * 1024 * 1024 * 1024);
  };
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "4G";
    MemoryMax = "6G";
    CPUQuota = "400%";
  };

  # lenovo's ntfy server (homelab.ntfy.baseUrl in its configuration)
  sam.workers.ntfyUrl = lib.mkDefault "http://${config.sam.fleet.hosts.lenovo-21CB001PMX.address}:2586/homelab-alerts";

  # Headless, Stylix has nothing to theme and its Home Manager half has failed an activation (#185).
  stylix.enable = lib.mkForce desktop;

  # Without this unit time-sync.target is reached on an unsynchronised clock and a reset RTC fires every calendar timer when NTP steps it.
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "sysinit.target" ];

  # No catch-up run at boot, while k3s and workers start.
  nix.gc.persistent = false;
  nix.optimise.persistent = false;

  systemd.services.nix-optimise.after = [ "nix-gc.service" ];

  # NetworkManager.conf is its restart trigger and a restart drops wifi: keep it, sysctl and modules-load the same with zero or more environments (modules/workers/core.nix).
  networking.nat.enable = true;
  boot.enableContainers = true;
  networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

  assertions =
    let
      found =
        lib.optional config.stylix.enable "Stylix"
        ++ lib.optional (
          config.home-manager.users.${config.sam.profile.username} ? stylix
        ) "Home Manager Stylix"
        ++ lib.optional config.services.displayManager.enable "a display manager"
        ++ lib.optional config.services.xserver.enable "an X server";
    in
    [
      {
        assertion = desktop || found == [ ];
        message = "role runtime-host: the default boot is headless; Stylix, a display manager or an X server belong in a desktop specialisation (sam.desktop.enable); found: ${lib.concatStringsSep ", " found}.";
      }
    ];
}
