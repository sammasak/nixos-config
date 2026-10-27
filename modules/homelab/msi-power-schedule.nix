# Work-hours power window for msi-ms7758, a dual-boot tower only wanted awake
# then. No weekend wake fires, so it stays off from Fri 21:00 to Mon 09:00.
#
# Graceful note: we deliberately do a local graceful stop rather than an API
# `kubectl cordon`/`drain`. msi runs a single stateless pod (ollama-msi, model
# on a PVC) behind a NoSchedule taint, and its NotReady periods are alerting-
# muted. Stopping k3s.service SIGTERMs that pod cleanly before poweroff, which
# is all drain would buy here — without a cross-repo RBAC token or having to
# un-cordon the node on every morning wake.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkMerge;
  cfg = config.homelab.msiPowerSchedule;
  msiMac = "d4:3d:7e:4a:f9:3d";
in
{
  options.homelab.msiPowerSchedule = {
    waker.enable = mkEnableOption "sending msi its Mon-Fri 09:00 Wake-on-LAN packet (enable on an always-on host)";
    selfShutdown.enable = mkEnableOption "msi's scheduled Mon-Fri 21:00 graceful poweroff (enable on msi)";
  };

  config = mkMerge [
    (mkIf cfg.waker.enable {
      systemd.services.msi-wake = {
        description = "Wake msi-ms7758 via Wake-on-LAN";
        # WoL is best-effort: a failed send must not leave a failed unit around.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.wakeonlan}/bin/wakeonlan ${msiMac}";
        };
      };
      systemd.timers.msi-wake = {
        description = "Wake msi-ms7758 on the work-hours schedule";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Mon-Fri 09:00";
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
          OnCalendar = "Mon-Fri 21:00";
          # No catch-up: if msi was off at 21:00 it is already where we want it.
          Persistent = false;
        };
      };
    })
  ];
}
