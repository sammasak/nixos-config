# Scheduled power window for the intermittent msi-ms7758 worker.
#
# msi runs the "bigger/faster" ollama tier (llama3.1:8b) but is a dual-boot
# tower we only want awake during work hours. Two halves, enabled on different
# hosts:
#
#   * waker       — runs on an ALWAYS-ON host (the control plane). Sends a
#                   Wake-on-LAN magic packet Mon-Fri at 09:00 so msi boots.
#   * selfShutdown — runs ON msi. Mon-Fri at 21:00 it stops k3s (so the ollama
#                   pod gets SIGTERM and terminates within its grace period),
#                   then powers off. No weekend wake fires, so it stays off from
#                   Fri 21:00 to Mon 09:00.
#
# Graceful note: we deliberately do a local graceful stop rather than an API
# `kubectl cordon`/`drain`. msi runs a single stateless pod (ollama-msi, model
# on a PVC) behind a NoSchedule taint, and its NotReady periods are alerting-
# muted. Stopping k3s.service SIGTERMs that pod cleanly before poweroff, which
# is all drain would buy here — without a cross-repo RBAC token or having to
# un-cordon the node on every morning wake.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.homelab.msiPowerSchedule;
in
{
  options.homelab.msiPowerSchedule = {
    waker = {
      enable = mkEnableOption "sending msi its Mon-Fri 09:00 Wake-on-LAN packet (enable on an always-on host)";
      mac = mkOption {
        type = types.str;
        default = "d4:3d:7e:4a:f9:3d";
        description = "MAC address of msi's enp3s0 (the Wake-on-LAN target).";
      };
      onCalendar = mkOption {
        type = types.str;
        default = "Mon-Fri 09:00";
        description = "systemd OnCalendar for the wake packet (system timezone).";
      };
    };

    selfShutdown = {
      enable = mkEnableOption "msi's scheduled Mon-Fri 21:00 graceful poweroff (enable on msi)";
      onCalendar = mkOption {
        type = types.str;
        default = "Mon-Fri 21:00";
        description = "systemd OnCalendar for the scheduled shutdown (system timezone).";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.waker.enable {
      systemd.services.msi-wake = {
        description = "Wake msi-ms7758 via Wake-on-LAN";
        # WoL is best-effort: a failed send must not leave a failed unit around.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.wakeonlan}/bin/wakeonlan ${cfg.waker.mac}";
        };
      };
      systemd.timers.msi-wake = {
        description = "Wake msi-ms7758 on the work-hours schedule";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.waker.onCalendar;
          # Do NOT catch up a missed wake (e.g. a weekend boot of the control
          # plane) — only wake at the real scheduled tick.
          Persistent = false;
        };
      };
    })

    (mkIf cfg.selfShutdown.enable {
      systemd.services.msi-scheduled-shutdown = {
        description = "Graceful scheduled shutdown of msi (drain workloads, then poweroff)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "msi-scheduled-shutdown" ''
            set -u
            echo "Scheduled shutdown: stopping k3s to drain workloads gracefully..."
            # Stopping k3s SIGTERMs the kubelet/containerd, so ollama-msi (and any
            # other tolerating pod) terminates within its grace period before the
            # node powers down.
            ${pkgs.systemd}/bin/systemctl stop k3s.service || true
            ${pkgs.coreutils}/bin/sleep 5
            echo "Powering off."
            ${pkgs.systemd}/bin/systemctl poweroff
          '';
        };
      };
      systemd.timers.msi-scheduled-shutdown = {
        description = "Scheduled work-hours shutdown of msi";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.selfShutdown.onCalendar;
          # No catch-up: if msi was off at 21:00 it is already where we want it.
          Persistent = false;
        };
      };
    })
  ];
}
