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
        Description = "Board Daemon — watches knowledge Board and dispatches ntfy events";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = [
          pathEnv
          "BOARD_DIR=${home}/knowledge/Board"
          "KNOWLEDGE_VAULT_DIR=${home}/knowledge"
          "NTFY_URL=http://ntfy.ntfy.svc.cluster.local/homelab-alerts"
          "WEBHOOK_PORT=8765"
          "RUST_LOG=board_daemon=info"
          "IMPROVEMENT_LOOP_DIR=${home}/homelab-improvement-loop"
          "CLAUDE_BIN=${profile}/bin/claude"
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
    e2e-tester = mkService {
      description = "Homelab E2E Tester";
      goalPath = "${loop}/e2e-tester/test-monitor/GOAL.md";
      extraService.TimeoutStartSec = 1800;
    };

    check-infra = {
      Unit = {
        Description = "Infra health check — posts to board-daemon on issues";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = pathEnv;
        Type = "oneshot";
        ExecStart = "${loop}/checks/check-infra.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 60;
      };
    };
    check-product = {
      Unit = {
        Description = "Product health check — posts to board-daemon on issues";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = pathEnv;
        Type = "oneshot";
        ExecStart = "${loop}/checks/check-product.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 60;
      };
    };
    check-secrets = {
      Unit = {
        Description = "Secrets/cert expiry check — posts to board-daemon on issues";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = pathEnv;
        Type = "oneshot";
        ExecStart = "${loop}/checks/check-secrets.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 60;
      };
    };
    check-devex = {
      Unit = {
        Description = "DevEx stale PR/ticket check — posts to board-daemon on issues";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = pathEnv;
        Type = "oneshot";
        ExecStart = "${loop}/checks/check-devex.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 60;
      };
    };

    meta-watchdog = {
      Unit = {
        Description = "Meta-Watchdog: non-Claude agent health monitor";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = pathEnv;
        Type = "oneshot";
        ExecStart = "${loop}/meta-watchdog.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 60;
      };
    };
  };

  systemd.user.timers = {
    e2e-tester = mkTimer {
      description = "Homelab E2E Tester — daily";
      onCalendar = "*-*-* 03:00:00";
    };
    check-infra = mkTimer {
      description = "Infra health check — every 5 min";
      onCalendar = "*:0/5:00";
    };
    check-product = mkTimer {
      description = "Product health check — every 5 min";
      onCalendar = "*:0/5:00";
    };
    check-secrets = mkTimer {
      description = "Secrets/cert expiry check — every 6h";
      onCalendar = "*-*-* 0/6:00:00";
    };
    check-devex = mkTimer {
      description = "DevEx stale PR/ticket check — daily";
      onCalendar = "*-*-* 09:00:00";
    };
    meta-watchdog = mkTimer {
      description = "Meta-Watchdog — every 30 min";
      onCalendar = "*:0/30:00";
      extraTimer = {
        OnBootSec = "5min";
        RandomizedDelaySec = "60";
        Persistent = true;
      };
    };
  };
}
