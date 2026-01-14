# Automation for system updates and backups
{ config, pkgs, ... }:
{
  # Automatic system updates
  system.autoUpgrade = {
    enable = true;
    flake = "/home/lukas/nixos-config";
    flags = [
      "--update-input" "nixpkgs"
      "--commit-lock-file"
    ];
    dates = "Sun 03:00";  # Run every Sunday at 3 AM
    allowReboot = false;  # Don't automatically reboot (safer)
  };

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "monthly";
    options = "--delete-older-than 30d";
  };

  # Keep reasonable number of generations for rollback
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.grub.configurationLimit = 10;

  # Optimize nix store automatically
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # Systemd service to clean up home-manager backups
  systemd.services.cleanup-hm-backups = {
    description = "Clean up old home-manager backup files";
    serviceConfig = {
      Type = "oneshot";
      User = "lukas";
    };
    script = ''
      # Remove backup files older than 7 days
      ${pkgs.findutils}/bin/find $HOME -name "*.backup" -type f -mtime +7 -delete
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
}
