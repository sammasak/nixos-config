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

  # Delivers the workers' credential (claude_oauth_token), and nix_access_token.
  sam.hostSecrets.enable = true;

  # What an environment builds here, the other hosts download (modules/core/store-cache.nix).
  sam.storeCache = { serve = true; use = true; };

  # Theming only where a desktop boots (#185): headless, Stylix has nothing to theme and its
  # Home Manager half has failed an activation. A desktop specialisation gets it back.
  stylix.enable = lib.mkForce desktop;

  # Calendar timers are ordered after time-sync.target, which without this unit is reached on an
  # unsynchronised clock: a boot with a reset RTC then fires every one of them when NTP steps it.
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "sysinit.target" ];

  # No catch-up run at boot, while k3s and workers start: a missed slot waits for the next one.
  nix.gc.persistent = false;
  nix.optimise.persistent = false;
  system.autoUpgrade.persistent = false;

  # One store-heavy job at a time, should their slots ever meet.
  systemd.services.nix-optimise.after = [ "nix-gc.service" ];
  systemd.services.nixos-upgrade = {
    after = [ "nix-gc.service" "nix-optimise.service" ];
    # notify-send needs a session bus: headless, the hook only adds a failed unit.
    onSuccess = lib.mkIf (!desktop) (lib.mkForce [ ]);
    onFailure = lib.mkIf (!desktop) (lib.mkForce [ ]);
  };

  assertions = [
    {
      assertion = desktop || !(config.stylix.enable || config.services.displayManager.enable || config.services.xserver.enable);
      message = "role runtime-host: the default boot is headless; Stylix, a display manager or an X server belong in a desktop specialisation (sam.desktop.enable).";
    }
  ];
}
