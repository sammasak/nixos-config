# Zero-token wake-up for the coordinator host: a user timer runs the read-only
# coord:changed task from the writable skills checkout, and a headless,
# spend-capped Coordinator session starts only when that task printed an
# actionable change, so an idle tick makes no model call at all.
{ config, lib, pkgs, osConfig, ... }:
let
  wk = osConfig.sam.herdr.coordinatorWakeup;
  coordinatorHost = (osConfig.sam.herdr.machines or [ ]) != [ ];
  wakeup = pkgs.writeShellApplication {
    name = "coordinator-wakeup";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.util-linux pkgs.gnugrep pkgs.gnused pkgs.herdr ];
    text = ''
      skills="''${COORDINATOR_SKILLS_DIR:-$HOME/claude-code-skills}"
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/coordinator/changed"
      budget="''${COORDINATOR_WAKEUP_BUDGET_USD:-${wk.maxBudgetUsd}}"
      log() { printf 'coordinator-wakeup: %s\n' "$*"; }
      [ -r "$skills/devenv.nix" ] || { log "no skills checkout at $skills; nothing checked"; exit 0; }
      mkdir -p "$state"
      cd "$skills"
      if ! devenv tasks run coord:changed > "$state/run.log" 2>&1; then
        if grep -q 'Task does not exist: coord:changed' "$state/run.log"; then
          log "coord:changed is not in $skills yet (pull the checkout); nothing checked"; exit 0
        fi
        log "coord:changed failed: $(grep -vE '^\s*$' "$state/run.log" | tail -n 3 | tr '\n' ' ')"; exit 1
      fi
      rec="$state/latest.json"
      n=$(jq -r '.changes | length' "$rec" 2>/dev/null) || { log "no readable $rec after the run"; exit 1; }
      [ "$n" -gt 0 ] || exit 0
      lines=$(jq -r '.changes[].line' "$rec")
      exec 9>"$state/session.lock"
      flock -n 9 || { log "a wake-up session is still running; $n change(s) kept in $rec"; exit 0; }
      ts=$(date -u +%Y%m%dT%H%M%SZ); report="$state/wake-$ts.md"
      log "$n actionable change(s); starting one Coordinator session (budget $budget USD) -> $report"
      printf '%s\n' "$lines" | sed 's/^/coordinator-wakeup:   /'
      prompt=$(printf 'Unattended wake-up at %s: coord:changed found these actionable changes since its last run:\n%s\n\nRun coord:brief and report in Markdown: what needs the owner, which handoffs settled and whether their work is verified (evidence_ref), and what you would do next. This session only reports: do not send handoffs, labels or comments.' "$ts" "$lines")
      rc=0
      claude -p --agent coordinator --max-budget-usd "$budget" --output-format text "$prompt" > "$report" 2> "$state/wake-$ts.err" < /dev/null || rc=$?
      [ "$rc" -eq 0 ] || log "claude exited $rc (see $state/wake-$ts.err)"
      herdr notification show "Coordinator: $n change(s)" --body "$(head -c 180 "$report" | tr '\n' ' ')" --sound request >/dev/null 2>&1 || true
      exit "$rc"
    '';
  };
in
{
  config = lib.mkIf (coordinatorHost && wk.enable) {
    home.packages = [ wakeup ];

    systemd.user.services.coordinator-wakeup = {
      Unit = {
        Description = "coord:changed; a Coordinator session only on actionable output";
        After = [ "herdr.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${wakeup}/bin/coordinator-wakeup";
        # devenv and claude come from the system and user profiles, not from the script's closure.
        Environment = [ "PATH=/run/current-system/sw/bin:${config.home.profileDirectory}/bin" ];
        TimeoutStartSec = "30min";
        Nice = 10;
        MemoryMax = "3G";
      };
    };

    systemd.user.timers.coordinator-wakeup = {
      Unit.Description = "coord:changed every ${wk.interval} of idleness";
      Timer = {
        OnBootSec = "3min";
        OnUnitInactiveSec = wk.interval;
        AccuracySec = "30s";
        Unit = "coordinator-wakeup.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
