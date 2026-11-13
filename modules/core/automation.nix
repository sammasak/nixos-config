{ config, pkgs, ... }:
let
  username = config.sam.profile.username;
in
{
  assertions = [{
    assertion = !config.system.autoUpgrade.enable;
    message = "system.autoUpgrade must stay off: an unattended switch from main bypasses deploy-rs rollback and the health check; deploy with `just deploy HOST` (docs/k3s-to-nixos-native.md).";
  }];

  nix.gc = {
    automatic = true;
    dates = "monthly";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  systemd.services.cleanup-hm-backups = {
    description = "Clean up old home-manager backup files";
    serviceConfig = {
      Type = "oneshot";
      User = username;
    };
    enableStrictShellChecks = true;
    script = ''
      ${pkgs.findutils}/bin/find "$HOME" -name "*.backup" -type f -mtime +7 -delete
      echo "Cleaned up home-manager backups older than 7 days"
    '';
  };

  systemd.timers.cleanup-hm-backups = {
    description = "Timer for cleaning up home-manager backups";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  systemd.services.nix-gc.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    IOWeight = 10;
  };

  systemd.services.nix-optimise.serviceConfig = {
    Nice = 19;
    IOSchedulingClass = "idle";
    IOWeight = 10;
  };
}
