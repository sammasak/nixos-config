# Automation for system updates and cleanup
{ config, pkgs, host, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
  username = vars.username;
  uid = toString config.users.users.${username}.uid;
  notifyScript = pkgs.writeShellScript "nixos-upgrade-notify" ''
    status="$1"
    runtime_dir="/run/user/${uid}"

    if [ ! -d "$runtime_dir" ]; then
      exit 0
    fi

    export XDG_RUNTIME_DIR="$runtime_dir"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
    export DISPLAY=":0"

    ${pkgs.libnotify}/bin/notify-send "NixOS Auto Upgrade" "$status"
  '';
in
{
  system.autoUpgrade = {
    enable = true;
    flake = "/home/lukas/nixos-config";
    flags = [
      "--update-input"
      "nixpkgs"
      "--commit-lock-file"
      "--print-build-logs"
    ];
    dates = "Sun 03:00";
    allowReboot = false;
  };

  nix.gc = {
    automatic = true;
    dates = "monthly";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # Clean up home-manager backup files
  systemd.services.cleanup-hm-backups = {
    description = "Clean up old home-manager backup files";
    serviceConfig = {
      Type = "oneshot";
      User = "lukas";
    };
    script = ''
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

  systemd.services.nixos-upgrade = {
    onSuccess = [ "nixos-upgrade-notify-success.service" ];
    onFailure = [ "nixos-upgrade-notify-failure.service" ];
  };

  systemd.services.nixos-upgrade-notify-success = {
    description = "Notify user about successful NixOS auto-upgrade";
    serviceConfig.Type = "oneshot";
    script = ''${notifyScript} "Upgrade completed successfully"'';
  };

  systemd.services.nixos-upgrade-notify-failure = {
    description = "Notify user about failed NixOS auto-upgrade";
    serviceConfig.Type = "oneshot";
    script = ''${notifyScript} "Upgrade failed - check journalctl -u nixos-upgrade"'';
  };
}
