# Non-interactive nixos-rebuild switch trigger for the homelab board worker.
#
# Problem: the improvement-loop agents run Claude Code inside a bubblewrap sandbox
# where setuid is stripped, so `sudo nixos-rebuild` fails even with a NOPASSWD rule.
#
# Solution: a root-level path-activated service that fires when the lukas user
# (or the board worker VM via SSH) writes a trigger file.  No setuid, no polkit —
# just a group-writable directory the unprivileged user can write to.
#
# Trigger (from improvement-loop agent or board worker SSH):
#   echo "requester=board-worker" > /run/nixos-rebuild-trigger/request
#
# Poll result (blocks until status= appears):
#   grep -m1 'status=' /run/nixos-rebuild-trigger/result
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.nixosRebuildTrigger;
  username = config.sam.profile.username;
  triggerDir = "/run/nixos-rebuild-trigger";
  triggerFile = "${triggerDir}/request";
  resultFile = "${triggerDir}/result";
in
{
  options.homelab.nixosRebuildTrigger = {
    enable = mkEnableOption "path-activated nixos-rebuild switch for board worker";

    flakePath = mkOption {
      type = types.str;
      default = "/home/${username}/nixos-config";
      description = ''
        Absolute path to the nixos-config flake on this host.
        Only local paths are accepted — no URI schemes or remote refs.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Trigger directory: writable by the primary user so bubblewrap agents and
    # the board worker (via SSH) can write the request file without sudo.
    systemd.tmpfiles.rules = [
      "d ${triggerDir} 0770 root ${username} -"
    ];

    # Arm when request file exists; activate the rebuild service.
    systemd.paths.nixos-rebuild-trigger = {
      description = "Board-worker nixos-rebuild switch trigger (path watch)";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathExists = triggerFile;
    };

    # Privileged oneshot: removes the trigger, runs nixos-rebuild, writes result.
    # Audit trail: journald (identifier nixos-rebuild-trigger) + resultFile per run.
    # Privilege surface: root only for this one command; no shell access granted.
    systemd.services.nixos-rebuild-trigger = {
      description = "Non-interactive nixos-rebuild switch (board-worker trigger)";
      after = [ "nix-daemon.service" ];
      wants = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        SyslogIdentifier = "nixos-rebuild-trigger";
        TimeoutStartSec = 1800;
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = [ "/run/current-system/sw/bin" ] ++ (with pkgs; [ git openssh ]);
      script = ''
        set -euo pipefail
        FLAKE="${cfg.flakePath}#${config.networking.hostName}"

        # Snapshot and remove trigger before rebuilding to prevent re-arm loop.
        REQUESTER=$(cat "${triggerFile}" 2>/dev/null | head -1 | tr -dc '[:print:]' | cut -c1-128 || echo "unknown")
        rm -f "${triggerFile}"

        echo "start=$(date -Iseconds) flake=$FLAKE requester=$REQUESTER status=running" > "${resultFile}"
        echo "nixos-rebuild-trigger: starting rebuild of $FLAKE (requester: $REQUESTER)"

        if nixos-rebuild switch --flake "$FLAKE"; then
          echo "start=$(date -Iseconds) flake=$FLAKE requester=$REQUESTER status=success" > "${resultFile}"
          echo "nixos-rebuild-trigger: rebuild succeeded"
          # Best-effort: prompt the user session to reload new Home Manager units.
          systemctl --machine=${username}@ --user daemon-reload 2>/dev/null || true
        else
          echo "start=$(date -Iseconds) flake=$FLAKE requester=$REQUESTER status=failed" > "${resultFile}"
          echo "nixos-rebuild-trigger: rebuild FAILED" >&2
          exit 1
        fi
      '';
    };
  };
}
