# Non-interactive nixos-rebuild trigger for the homelab board worker.
#
# Problem: the improvement-loop agents run Claude Code inside a bubblewrap sandbox
# where setuid is stripped, so `sudo nixos-rebuild` fails even with a NOPASSWD
# rule. Polkit has the same limitation. They need a non-interactive way to deploy
# a config change to the lenovo control plane.
#
# SECURITY MODEL (devex-052 rework):
#   This grants the trigger principal NON-INTERACTIVE CONTROL-PLANE DEPLOY. That
#   is a deliberate trust choice. The hardening below removes the arbitrary-root
#   execution hole and adds deploy safety, but it cannot remove the underlying
#   trust: anyone who can write the request file can deploy any committed,
#   pushed revision of sammasak/nixos-config to lenovo. Gate the first uses
#   behind human approval.
#
#   1. PINNED, INTEGRITY-CHECKED SOURCE. The rebuild does NOT read the
#      agent-writable local clone (/home/lukas/nixos-config). It rebuilds from
#      `github:sammasak/nixos-config/<rev>#lenovo`, where <rev> is a 40-char git
#      SHA supplied in the request. nix fetches that exact immutable commit fresh
#      from the remote and verifies it; the triggering agent cannot mutate the
#      Nix that runs as root. A floating ref (branch name) is rejected - only a
#      full commit SHA is accepted, so the deployed tree is reproducible and
#      auditable. The private repo is fetched using root's existing nix.conf
#      `access-tokens` line (sourced from SOPS at /run/secrets/nix_access_token);
#      no token is hardcoded here.
#
#   2. HEALTH-GATED with AUTOMATIC ROLLBACK, RUN OUT-OF-BAND. We `nixos-rebuild
#      boot` the new generation (staged as the next-boot default but NOT
#      activated), then activate it live with `switch-to-configuration switch`.
#      A post-activation health gate checks: k3s API on :6443, sshd listening on
#      :22, and DNS resolution. If any check fails within the timeout, we
#      automatically roll back: re-activate the previous generation and reset it
#      as the boot default. No bare `switch` without recovery is ever used.
#
#      CRITICAL: the activation tail does NOT run inside this service.
#      `switch-to-configuration` stops every unit whose definition changed — and
#      nixos-rebuild-trigger.service is itself part of the configuration being
#      activated. Running the switch inline meant the switch SIGTERM'd the shell
#      that was running it, mid-stop-phase. Observed 2026-08-26: the deployed rev
#      changed this very unit, so the stop phase listed
#      "k3s.service, nixos-rebuild-trigger.service, polkit.service", killed the
#      switch (status=15/TERM), and activation aborted AFTER stopping units and
#      BEFORE the start phase. k3s stayed down; no result was ever written; the
#      health gate and rollback never ran. The deploy safety net was itself
#      destroyed by the deploy.
#
#      So once the build succeeds, this service hands the remaining work to a
#      DETACHED transient unit (`systemd-run --unit=nixos-rebuild-activation`)
#      and exits. A transient unit lives in /run/systemd/transient and is not
#      part of any generation's unit set, so switch-to-configuration neither
#      knows nor cares about it and can never stop it. The trigger service
#      records `staged-and-activating`; the transient unit writes the final
#      result.
#
#   3. DEPLOY LOCK. A flock on a persistent lockfile serializes deploys so two
#      triggers (or a deploy racing other Nix work) cannot overlap. A concurrent
#      request is rejected rather than queued. The lock is re-acquired by the
#      activation unit across the handoff - see the comment there.
#
#   4. APPEND-ONLY AUDIT LOG outside /run, at /var/log/nixos-rebuild-trigger.log
#      (root-owned, 0640). Each line records timestamp, requester, resolved rev,
#      and result. /run/.../result remains as a transient status file for pollers.
#
# Trigger (from improvement-loop agent or board worker SSH):
#   printf 'requester=board-worker\nrev=<40-char-git-sha>\n' \
#     > /run/nixos-rebuild-trigger/request
#
# Poll result. NOTE: `status=staged-and-activating` is NOT terminal - it means
# the build is done and the detached activation unit has taken over. Poll until
# the status is one of: success, failed-build, failed-activate-rolledback,
# failed-health-rolledback, failed-activation-lock, rejected-bad-rev,
# rejected-locked, rejected-activating.
#   grep -m1 'status=' /run/nixos-rebuild-trigger/result
#   systemctl status nixos-rebuild-activation.service   # while it runs
#   journalctl -t nixos-rebuild-activation
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.nixosRebuildTrigger;
  username = config.sam.profile.username;
  # The primary group of the trigger principal. Resolved from the user rather
  # than assumed to be eponymous: NixOS gives a normal user the shared `users`
  # group by default, so `${username}` is NOT a group that exists. A tmpfiles
  # rule naming a non-existent group is silently useless.
  triggerGroup = config.users.users.${username}.group;
  triggerDir = "/run/nixos-rebuild-trigger";
  triggerFile = "${triggerDir}/request";
  resultFile = "${triggerDir}/result";
  auditLog = "/var/log/nixos-rebuild-trigger.log";
  lockFile = "/var/lib/nixos-rebuild-trigger/deploy.lock";
  activationUnit = "nixos-rebuild-activation";

  # Tools needed by both the trigger service and the detached activation script.
  # The activation script runs under a transient unit with no inherited PATH, so
  # it cannot rely on the service's `path =` list and sets its own from this.
  runtimePkgs = with pkgs; [
    nixos-rebuild
    git
    openssh
    util-linux
    iproute2
    curl
    coreutils
    gnugrep
    gnused
    systemd
  ];

  # ── The activation tail, extracted so it can run OUT OF BAND ──────────────
  # Everything from "activate the staged generation" onwards lives here:
  # switch-to-configuration, the post-activation health gate, rollback, and the
  # result/audit writes for those phases.
  #
  # This is deliberately NOT part of the trigger service's script. See note 2 in
  # the header: switch-to-configuration stops units whose definitions changed,
  # the trigger service is one of them, and running the switch inline meant the
  # switch killed itself mid-stop-phase and left the machine half-activated.
  # Launched via `systemd-run` it lives in a transient unit that no generation
  # owns, so the switch cannot stop it.
  #
  # Args: PREV_SYSTEM REQUESTER REV TS
  activationScript = pkgs.writeShellScript "nixos-rebuild-activate" ''
    set -euo pipefail

    export PATH=${lib.makeBinPath runtimePkgs}:/run/current-system/sw/bin

    PREV_SYSTEM="$1"
    REQUESTER="$2"
    REV="$3"
    TS="$4"

    # Same formats as the trigger service - a poller or log reader cannot tell
    # which of the two units wrote a given line, and should not need to.
    audit() {
      printf '%s requester=%s rev=%s %s\n' "$(date -Iseconds)" "$REQUESTER" "''${REV:-none}" "$1" >> "${auditLog}"
    }
    result() {
      printf 'start=%s requester=%s rev=%s status=%s\n' "$TS" "$REQUESTER" "''${REV:-none}" "$1" > "${resultFile}"
    }

    # --- Deploy lock across the handoff -------------------------------------
    # DESIGN CHOICE: the lock is re-acquired here rather than inherited. flock
    # is held via an open fd, and a transient unit is forked by PID 1 rather
    # than by us, so the trigger service's fd 9 cannot be passed across. We wait
    # for the lock instead of failing fast: at this point the trigger service
    # is exiting and about to release it, so the expected wait is milliseconds.
    #
    # This leaves a brief window in which neither unit holds the lock. A request
    # arriving exactly then could win the flock race and start a build while
    # this activation is still running. The trigger service closes that window
    # separately by rejecting any request while ${activationUnit}.service is
    # active, so the flock is a backstop rather than the only guard.
    exec 9>"${lockFile}"
    if ! flock -w 300 9; then
      result failed-activation-lock
      audit "result=failed-activation-lock detail=could-not-acquire-lock-within-300s prev=$PREV_SYSTEM"
      echo "nixos-rebuild-activation: could not acquire the deploy lock; staged generation NOT activated" >&2
      exit 1
    fi

    # The staged generation is the newest system profile generation. Re-read it
    # here rather than trusting a value computed before the handoff.
    NEW_SYSTEM="$(readlink -f /nix/var/nix/profiles/system)"

    # --- Health gate --------------------------------------------------------
    # Checks, all must pass within ${toString cfg.healthTimeoutSec}s:
    #   1. k3s API server   - TCP/HTTPS reachable on 127.0.0.1:6443
    #   2. sshd             - listening on TCP :22 (don't lock ourselves out)
    #   3. DNS resolution   - resolve a public name (control-plane runs DNS)
    health_check() {
      local deadline=$(( $(date +%s) + ${toString cfg.healthTimeoutSec} ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        local ok=1
        # 1. k3s API: 401/403/200 over TLS all mean "answering".
        curl -sk --max-time 5 -o /dev/null https://127.0.0.1:6443/healthz \
          || curl -sk --max-time 5 -o /dev/null https://127.0.0.1:6443/ || ok=0
        # 2. sshd listening on :22.
        ss -ltn 2>/dev/null | grep -Eq ':22\b' || ok=0
        # 3. DNS resolves (this host serves DNS for the cluster).
        getent hosts github.com >/dev/null 2>&1 || ok=0
        if [ "$ok" -eq 1 ]; then return 0; fi
        sleep 5
      done
      return 1
    }

    rollback() {
      echo "nixos-rebuild-activation: ROLLING BACK to $PREV_SYSTEM" >&2
      # Re-activate the previous generation live...
      "$PREV_SYSTEM/bin/switch-to-configuration" switch || true
      # ...and reset it as the boot default.
      nixos-rebuild boot --rollback || true
    }

    # --- Activate the staged generation live --------------------------------
    echo "nixos-rebuild-activation: activating $NEW_SYSTEM (prev=$PREV_SYSTEM)"
    if ! "$NEW_SYSTEM/bin/switch-to-configuration" switch; then
      result failed-activate-rolledback
      audit "result=failed-activate-rolledback new=$NEW_SYSTEM prev=$PREV_SYSTEM"
      rollback
      echo "nixos-rebuild-activation: activation FAILED - rolled back" >&2
      exit 1
    fi

    # --- Post-activation health gate; rollback on failure -------------------
    if health_check; then
      result success
      audit "result=success new=$NEW_SYSTEM"
      echo "nixos-rebuild-activation: rebuild succeeded and health checks passed"
      # Best-effort: prompt the user session to reload new Home Manager units.
      systemctl --machine=${username}@ --user daemon-reload 2>/dev/null || true
    else
      result failed-health-rolledback
      audit "result=failed-health-rolledback new=$NEW_SYSTEM prev=$PREV_SYSTEM"
      rollback
      echo "nixos-rebuild-activation: health checks FAILED - rolled back to previous generation" >&2
      exit 1
    fi
  '';
in
{
  options.homelab.nixosRebuildTrigger = {
    enable = mkEnableOption "path-activated, health-gated nixos-rebuild for board worker";

    flakeRef = mkOption {
      type = types.str;
      default = "github:sammasak/nixos-config";
      description = ''
        Remote flake reference (without revision) the rebuild is pinned to.
        A full git SHA supplied in the request is appended as `/<rev>`. The local
        writable clone is deliberately NOT used - the source is always fetched
        fresh and integrity-checked from this remote so the triggering agent
        cannot inject Nix that runs as root.
      '';
    };

    hostAttr = mkOption {
      type = types.str;
      default = "lenovo";
      description = "nixosConfigurations attribute to build (flake#<hostAttr>).";
    };

    healthTimeoutSec = mkOption {
      type = types.int;
      default = 120;
      description = ''
        Seconds to wait for post-activation health checks (k3s API :6443, sshd,
        DNS) to pass before triggering an automatic rollback to the previous
        generation.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Trigger directory: writable by the primary user so bubblewrap agents and
    # the board worker (via SSH) can write the request file without sudo.
    #
    # WHO CAN TRIGGER: any member of the `${triggerGroup}` group. This is the
    # documented trust boundary for devex-052. Tightening to a dedicated,
    # narrowly-scoped service identity (e.g. a `board-deploy` group with only the
    # board worker's SSH key) is recommended as a follow-up; doing so only
    # requires changing the group here and in the provisioning unit below.
    systemd.tmpfiles.rules = [
      "d ${triggerDir} 0770 root ${triggerGroup} -"
      # Persistent state dir for the deploy lock (survives reboots, outside /run).
      "d /var/lib/nixos-rebuild-trigger 0700 root root -"
    ];

    # The tmpfiles rule above is NOT sufficient on its own, for two reasons:
    #
    #   1. /run is a tmpfs, and tmpfiles rules for it are applied only by
    #      systemd-tmpfiles-setup.service at BOOT. A `nixos-rebuild switch` that
    #      introduces or changes a /run rule renders the new
    #      /etc/tmpfiles.d/00-nixos.conf but does not re-run that service, so the
    #      directory stays missing — and the trigger stays dead — until the next
    #      reboot. That is exactly how this module shipped broken: the deployed
    #      generation carried the rule while the booted one did not.
    #   2. Nothing recreates the directory if it is removed mid-boot.
    #
    # This oneshot closes both gaps. It is pulled in by multi-user.target, so
    # activation starts it during a switch, and the path watcher orders itself
    # after it so the watch can never be armed against a missing directory.
    systemd.services.nixos-rebuild-trigger-dir = {
      description = "Provision the nixos-rebuild trigger request directory";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        install -d -m 0770 -o root -g ${triggerGroup} "${triggerDir}"
      '';
    };

    # Arm when request file exists; activate the rebuild service.
    systemd.paths.nixos-rebuild-trigger = {
      description = "Board-worker nixos-rebuild trigger (path watch)";
      wantedBy = [ "multi-user.target" ];
      # Wants, not Requires: a Requires on a oneshot would propagate the
      # oneshot's eventual stop back to the path unit.
      wants = [ "nixos-rebuild-trigger-dir.service" ];
      after = [ "nixos-rebuild-trigger-dir.service" ];
      pathConfig.PathExists = triggerFile;
    };

    # Privileged oneshot: validates the request, rebuilds from a PINNED remote
    # rev under a deploy lock, health-gates the activation, and auto-rolls-back
    # on failure. Audit trail: append-only ${auditLog} + journald + resultFile.
    systemd.services.nixos-rebuild-trigger = {
      description = "Pinned, health-gated nixos-rebuild (board-worker trigger)";
      after = [ "nix-daemon.service" "network-online.target" "nixos-rebuild-trigger-dir.service" ];
      wants = [ "nix-daemon.service" "network-online.target" "nixos-rebuild-trigger-dir.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        SyslogIdentifier = "nixos-rebuild-trigger";
        TimeoutStartSec = 3600;
        StandardOutput = "journal";
        StandardError = "journal";
      };
      path = [ "/run/current-system/sw/bin" ] ++ runtimePkgs;
      script = ''
        set -euo pipefail

        # --- Snapshot and consume the request first (prevents re-arm loop) ----
        # Consume the request FILE only. The directory must survive: it is the
        # trigger surface itself, and /run tmpfiles rules are re-applied only at
        # boot, so removing it here would disable the trigger until reboot.
        REQUEST_RAW="$(cat "${triggerFile}" 2>/dev/null || true)"
        rm -f "${triggerFile}"

        # Belt and braces: every status write below targets this directory, and
        # `set -e` would abort the run before any audit trail existed if it were
        # missing. Re-asserting it is idempotent.
        install -d -m 0770 -o root -g ${triggerGroup} "${triggerDir}"

        REQUESTER="$(printf '%s\n' "$REQUEST_RAW" | sed -n 's/^requester=//p' | head -1 | tr -dc '[:alnum:]._-' | cut -c1-128)"
        REV="$(printf '%s\n' "$REQUEST_RAW" | sed -n 's/^rev=//p' | head -1 | tr -dc '[:alnum:]' | cut -c1-64)"
        : "''${REQUESTER:=unknown}"
        TS="$(date -Iseconds)"

        audit() {
          # Append-only audit log outside /run.
          printf '%s requester=%s rev=%s %s\n' "$(date -Iseconds)" "$REQUESTER" "''${REV:-none}" "$1" >> "${auditLog}"
        }
        result() {
          printf 'start=%s requester=%s rev=%s status=%s\n' "$TS" "$REQUESTER" "''${REV:-none}" "$1" > "${resultFile}"
        }

        # --- Validate the pinned revision: must be a full 40-char git SHA. -----
        # A floating ref (branch/tag) is REJECTED so the deployed tree is
        # immutable, reproducible, and auditable.
        if ! printf '%s' "$REV" | grep -Eq '^[0-9a-f]{40}$'; then
          result rejected-bad-rev
          audit "result=rejected-bad-rev detail=rev-must-be-40-hex-sha"
          echo "nixos-rebuild-trigger: REJECTED - 'rev' must be a full 40-char git SHA (got: '$REV')" >&2
          exit 1
        fi

        FLAKE="${cfg.flakeRef}/$REV#${cfg.hostAttr}"
        result running
        audit "result=running flake=$FLAKE"
        echo "nixos-rebuild-trigger: requester=$REQUESTER rebuilding PINNED $FLAKE"

        # --- Deploy lock: serialize deploys; reject if one is already running. -
        exec 9>"${lockFile}"
        if ! flock -n 9; then
          result rejected-locked
          audit "result=rejected-locked detail=another-deploy-in-progress"
          echo "nixos-rebuild-trigger: REJECTED - another deploy holds the lock" >&2
          exit 1
        fi

        # The lock alone does not cover the window between this unit exiting and
        # the activation unit re-acquiring it (see the comment in the activation
        # script). Reject outright while an activation is in flight.
        if systemctl is-active --quiet ${activationUnit}.service; then
          result rejected-activating
          audit "result=rejected-activating detail=activation-already-in-flight"
          echo "nixos-rebuild-trigger: REJECTED - ${activationUnit}.service is still activating a previous deploy" >&2
          exit 1
        fi

        # Record the current generation so the activation unit can roll back to
        # it precisely. It must be captured HERE, before anything is activated.
        PREV_SYSTEM="$(readlink -f /run/current-system)"
        echo "nixos-rebuild-trigger: current generation = $PREV_SYSTEM"

        # --- Build + stage as boot default (does NOT activate live yet) -------
        if ! nixos-rebuild boot --flake "$FLAKE"; then
          result failed-build
          audit "result=failed-build flake=$FLAKE"
          echo "nixos-rebuild-trigger: build/boot staging FAILED" >&2
          exit 1
        fi

        NEW_SYSTEM="$(readlink -f /nix/var/nix/profiles/system)"

        # --- Hand the activation tail off to a DETACHED transient unit --------
        # This unit is part of the configuration being activated, so it cannot
        # run the switch itself: switch-to-configuration's stop phase would
        # SIGTERM this very script mid-switch, leaving units stopped and the
        # health gate and rollback unreachable (see note 2 in the header for the
        # 2026-08-26 incident that established this).
        #
        # `systemd-run` asks PID 1 to fork the activation, so it does not live
        # in this unit's cgroup and does not die with it. A transient unit is
        # not part of any generation's unit set, so the switch never stops it.
        # --collect reaps the unit once it finishes, success or failure.
        echo "nixos-rebuild-trigger: handing activation of $NEW_SYSTEM to ${activationUnit}.service"
        systemd-run \
          --collect \
          --unit=${activationUnit} \
          --quiet \
          --description="Detached activation + health gate for a board-worker nixos-rebuild" \
          --property=SyslogIdentifier=${activationUnit} \
          ${activationScript} "$PREV_SYSTEM" "$REQUESTER" "$REV" "$TS"

        # NOT a terminal state: the transient unit writes the final result.
        result staged-and-activating
        audit "result=staged-and-activating new=$NEW_SYSTEM prev=$PREV_SYSTEM handoff=${activationUnit}.service"
        echo "nixos-rebuild-trigger: build staged; ${activationUnit}.service owns the switch, health gate and rollback from here"
      '';
    };
  };
}
