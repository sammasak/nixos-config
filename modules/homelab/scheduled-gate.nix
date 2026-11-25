# The full nixos:qa on nixos-config's origin/main a few times a day, only when main has moved (pkgs/scheduled-gate):
# the pre-push hook runs the fast set and owes it. It runs as the owner, as a manual run does, from its own clone of
# the public repo; nixos:qa waits for the heavy-work lock itself, so it queues behind a build and never takes one's
# lane. Its gate and step records go to Loki as a push's did (mode=scheduled); the textfile here feeds
# ScheduledGateRed and ScheduledGateOverdue (modules/homelab/monitoring/rules/shipping.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.scheduledGate;
  user = config.sam.profile.username;
  dir = "/var/lib/scheduled-gate";
  metrics = "${dir}/metrics";
  runner = pkgs.callPackage ../../pkgs/scheduled-gate/package.nix { };
in
{
  imports = [ ./monitoring/node-exporter.nix ];

  options.homelab.scheduledGate.enable = lib.mkEnableOption "the scheduled full gate on nixos-config's main";

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${metrics}" ];
    # node-exporter counts a missing directory as a textfile scrape error until the first run
    systemd.tmpfiles.rules = [ "d ${metrics} 0755 ${user} - -" ];

    systemd.services.scheduled-gate = {
      description = "The full nixos:qa on nixos-config's origin/main, when it has moved";
      # the tests run the system's and the owner's tools, as from a login shell
      path = [
        config.nix.package
        pkgs.git
        pkgs.devenv
        "/run/wrappers"
        "/etc/profiles/per-user/${user}"
        "/run/current-system/sw"
      ];
      environment.HOME = "/home/${user}";
      serviceConfig = {
        Type = "oneshot";
        User = user;
        ExecStart = lib.escapeShellArgs [
          (lib.getExe runner)
          "--repo"
          "https://github.com/sammasak/nixos-config.git"
          "--state"
          dir
          "--metrics"
          "${metrics}/scheduled-gate.prom"
        ];
        StateDirectory = "scheduled-gate";
        StateDirectoryMode = "0755";
        # a wait behind another heavy job, then a 20 to 40 minute gate; a run killed here records nothing, so the
        # next timer run gates that head again
        TimeoutStartSec = "8h";
        Nice = 10;
      };
    };
    systemd.timers.scheduled-gate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # 12 h apart: ScheduledGateOverdue's 26 h (modules/homelab/monitoring/shipping-policy.json) lets one run be missed;
        # why twice: goals.md, Check tuning
        OnCalendar = "*-*-* 03,15:20:00";
        Persistent = true;
      };
    };
  };
}
