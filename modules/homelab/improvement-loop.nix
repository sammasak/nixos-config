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
    # board-daemon retired from the host: the canonical board-daemon now runs as a
    # Flux-managed Kubernetes Deployment in the `kanban` namespace (ingress
    # kanban.sammasak.dev, GitHub webhooks, board-daemon-secrets). Running a second
    # copy here made both instances fight over the same ~/knowledge/Board git repo
    # (index.lock contention). The timer-agents below remain — they perform periodic
    # passes and defer mutations to the live daemon.

    scrum-master = mkService {
      description = "Homelab Scrum Master — board management";
      goalPath = "${loop}/scrum-master/GOAL.md";
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
    oncall-monitor = mkService {
      description = "Homelab On-Call Monitor";
      # Canonical GOAL lives under monitors/oncall/ (matches the monitors/<name>/
      # detection layout: infra, product, secrets, devex all live there too).
      # The old oncall-monitor/GOAL.md path never existed in-tree; the loop had a
      # compensating symlink band-aid (oncall-monitor/GOAL.md -> ../monitors/oncall/
      # GOAL.md). Point straight at the real file so the unit no longer depends on
      # that symlink surviving (ticket-2026-06-19-devex-057).
      goalPath = "${loop}/monitors/oncall/GOAL.md";
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

    board-health = {
      Unit = {
        Description = "Board health watchdog — k8s board-daemon, auth, gh-drift, duplicate daemon";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Environment = [ pathEnv "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" ];
        Type = "oneshot";
        ExecStart = "${loop}/board-health.sh";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = 120;
      };
    };
  };

  systemd.user.timers = {
    # scrum-master.timer intentionally disabled: board-daemon is the authoritative
    # orchestrator (dispatch, transitions, backlog promotion, PR-merge poll). The
    # timer-driven scrum-master agent detects the live daemon and stands down every
    # run, so the timer only burned a no-op `claude` call every 15 min. The
    # scrum-master.service definition is kept for manual/ad-hoc runs. Re-add this
    # mkTimer block to restore the 15-min cadence.
    board-analyst = mkTimer {
      # Fires at :05 to avoid racing scrum-master.timer (every 15m starting :00)
      # on ~/knowledge/.git/index.lock (ticket-2026-06-12-devex-051).
      description = "Homelab Board Analyst — daily at 21:05";
      onCalendar = "*-*-* 21:05:00";
    };
    # Staggered onto distinct minutes (never a :00/:15/:30/:45 tick) to avoid
    # racing scrum-master.timer / board-analyst.timer on ~/knowledge/.git/index.lock
    # (devex-048; same index.lock race class as devex-051). RandomizedDelaySec adds
    # a further jitter window. Persistent = false matches this module's mkTimer default.
    oncall-monitor = mkTimer {
      description = "Homelab On-Call Monitor — every 4h at :10";
      onCalendar = "*-*-* 0/4:10:00";
      extraTimer.RandomizedDelaySec = "60";
    };
    progress-reviewer = mkTimer {
      description = "Homelab Progress Reviewer — hourly at :20";
      onCalendar = "*-*-* *:20:00";
      extraTimer.RandomizedDelaySec = "60";
    };
    gitops-reviewer = mkTimer {
      description = "Homelab GitOps PR Reviewer — daily at 21:35";
      onCalendar = "*-*-* 21:35:00";
      extraTimer.RandomizedDelaySec = "60";
    };
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
    board-health = mkTimer {
      description = "Board health watchdog — every 2h";
      onCalendar = "*-*-* 0/2:00:00";
      extraTimer = {
        OnBootSec = "3min";
        Persistent = true;
      };
    };
  };
}
