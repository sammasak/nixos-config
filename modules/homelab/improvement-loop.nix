# Home Manager module: homelab improvement loop systemd units
# Declares all services, timers, and path units for ~/homelab-improvement-loop.
# Import this module only for the homelab-server role (lenovo control plane).
{ config, ... }:
let
  home = config.home.homeDirectory;
  profile = config.home.profileDirectory;
  loop = "${home}/homelab-improvement-loop";
  runAgent = "${loop}/run-agent.sh";
  pathEnv = "PATH=${profile}/bin:/run/current-system/sw/bin";

  mkService = { description, goalPath, extraService ? {} }: {
    Unit = {
      Description = description;
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Environment = pathEnv;
      Type = "oneshot";
      ExecStart = "${runAgent} ${goalPath}";
      StandardOutput = "journal";
      StandardError = "journal";
      TimeoutStartSec = 900;
      TimeoutStopSec = 10;
    } // extraService;
  };

  mkTimer = { description, onCalendar, extraTimer ? {} }: {
    Unit.Description = description;
    Timer = {
      OnCalendar = onCalendar;
      AccuracySec = "1s";
      Persistent = false;
    } // extraTimer;
    Install.WantedBy = [ "timers.target" ];
  };
in
{
  systemd.user.services = {
    board-daemon = {
      Unit = {
        Description = "Board Daemon — watches knowledge-vault Board and dispatches ntfy events";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = [
          pathEnv
          "BOARD_DIR=${home}/knowledge-vault/Board"
          "KNOWLEDGE_VAULT_DIR=${home}/knowledge-vault"
          "NTFY_URL=http://ntfy.ntfy.svc.cluster.local/homelab-alerts"
          "WEBHOOK_PORT=8765"
          "RUST_LOG=board_daemon=info"
        ];
        Type = "simple";
        ExecStart = "${home}/board-daemon/target/release/board-daemon";
        Restart = "always";
        RestartSec = "5";
        StandardOutput = "journal";
        StandardError = "journal";
      };
      Install.WantedBy = [ "default.target" ];
    };
    board-analyst = mkService {
      description = "Homelab Board Analyst";
      goalPath = "${loop}/board-analyst/GOAL.md";
    };
    oncall-monitor = mkService {
      description = "Homelab On-Call Monitor";
      goalPath = "${loop}/monitors/oncall/GOAL.md";
    };
    gitops-reviewer = mkService {
      description = "Homelab GitOps PR Reviewer";
      goalPath = "${loop}/gitops-reviewer/GOAL.md";
    };
    conflict-resolver = mkService {
      description = "Homelab PR Conflict Resolver";
      goalPath = "${loop}/conflict-resolver/GOAL.md";
    };
    progress-reviewer = mkService {
      description = "Homelab Progress Reviewer";
      goalPath = "${loop}/progress-reviewer/GOAL.md";
    };
    infra-monitor = mkService {
      description = "Homelab Infra Monitor";
      goalPath = "${loop}/monitors/infra/GOAL.md";
    };
    e2e-tester = mkService {
      description = "Homelab E2E Tester";
      goalPath = "${loop}/e2e-tester/test-monitor/GOAL.md";
      extraService.TimeoutStartSec = 1800;
    };
    devex-monitor = mkService {
      description = "Homelab DevEx Monitor";
      goalPath = "${loop}/monitors/devex/GOAL.md";
    };
    secrets-monitor = mkService {
      description = "Homelab Secrets Monitor";
      goalPath = "${loop}/monitors/secrets/GOAL.md";
    };
    product-monitor = mkService {
      description = "Homelab Product Monitor";
      goalPath = "${loop}/monitors/product/GOAL.md";
    };
  };

  systemd.user.timers = {
    board-analyst = mkTimer {
      description = "Homelab Board Analyst — 2x daily at 06:05 and 18:05";
      onCalendar = "*-*-* 6/12:05:00";
      extraTimer.Persistent = true;
    };
    oncall-monitor = mkTimer {
      description = "Homelab On-Call Monitor — every 4h fallback";
      onCalendar = "*-*-* 0/4:05:00";
    };
    gitops-reviewer = mkTimer {
      description = "Homelab GitOps PR Reviewer — every 4h fallback";
      onCalendar = "*-*-* 0/4:12:00";
    };
    conflict-resolver = mkTimer {
      description = "Homelab PR Conflict Resolver — every 12h fallback";
      onCalendar = "*-*-* 0/12:20:00";
    };
    progress-reviewer = mkTimer {
      description = "Homelab Progress Reviewer — every 4 hours";
      onCalendar = "*-*-* 0/4:15:00";
    };
    infra-monitor = mkTimer {
      description = "Homelab Infra Monitor — daily";
      onCalendar = "*-*-* 22:00:00";
    };
    e2e-tester = mkTimer {
      description = "Homelab E2E Tester — daily";
      onCalendar = "*-*-* 03:00:00";
    };
    devex-monitor = mkTimer {
      description = "Homelab DevEx Monitor — weekly Monday";
      onCalendar = "Mon *-*-* 21:00:00";
    };
    secrets-monitor = mkTimer {
      description = "Homelab Secrets Monitor — weekly Tuesday";
      onCalendar = "Tue *-*-* 21:00:00";
    };
    product-monitor = mkTimer {
      description = "Homelab Product Monitor — weekly Thursday";
      onCalendar = "Thu *-*-* 21:00:00";
    };
  };
}
