# Path-activated, health-gated nixos-rebuild for a non-interactive deployer.
# Enabling this grants the trigger principal CONTROL-PLANE DEPLOY: anyone who can
# write /run/nixos-rebuild-trigger/request can deploy any pushed revision of
# sammasak/nixos-config to this host. The rebuild source is a pinned 40-char SHA
# fetched from the remote, never the local clone. Never deploy a change to THIS
# module through the trigger itself.
# See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.nixosRebuildTrigger;
  username = config.sam.profile.username;
  # Resolved, not assumed eponymous: NixOS gives a normal user the shared `users`
  # group, and a tmpfiles rule naming a non-existent group is silently useless.
  triggerGroup = config.users.users.${username}.group;
  triggerDir = "/run/nixos-rebuild-trigger";
  triggerFile = "${triggerDir}/request";
  resultFile = "${triggerDir}/result";
  auditLog = "/var/log/nixos-rebuild-trigger.log";
  lockFile = "/var/lib/nixos-rebuild-trigger/deploy.lock";
  activationUnit = "nixos-rebuild-activation";

  # Shared by both units. The activation script runs under a transient unit with
  # no inherited PATH, so it cannot use the service's `path =` and sets its own.
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

  # The activation tail — switch, health gate, rollback — runs OUT OF BAND under
  # a transient unit. It cannot live in the trigger service: switch-to-
  # configuration stops every unit whose definition changed, the trigger service
  # is one of them, and an inline switch SIGTERMs itself mid-stop-phase.
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
    # WHO CAN TRIGGER: any member of `${triggerGroup}` — 0770 is what makes the
    # request file writable without sudo, and it is the whole trust boundary.
    systemd.tmpfiles.rules = [
      "d ${triggerDir} 0770 root ${triggerGroup} -"
      # Persistent state dir for the deploy lock (survives reboots, outside /run).
      "d /var/lib/nixos-rebuild-trigger 0700 root root -"
    ];

    # The tmpfiles rule alone is not enough: /run rules are applied only at boot
    # by systemd-tmpfiles-setup, so a switch that introduces one leaves the
    # directory missing — and the trigger dead — until the next reboot. That is
    # how this module first shipped broken. This oneshot runs during activation.
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

    systemd.paths.nixos-rebuild-trigger = {
      description = "Board-worker nixos-rebuild trigger (path watch)";
      wantedBy = [ "multi-user.target" ];
      # Wants, not Requires: a Requires on a oneshot would propagate the
      # oneshot's eventual stop back to the path unit.
      wants = [ "nixos-rebuild-trigger-dir.service" ];
      after = [ "nixos-rebuild-trigger-dir.service" ];
      pathConfig.PathExists = triggerFile;
    };

    # Audit trail: append-only ${auditLog}, journald, and ${resultFile} for pollers.
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
