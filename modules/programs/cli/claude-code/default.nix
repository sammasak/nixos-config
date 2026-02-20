# Claude Code agent configuration — settings, env sourcing, heartbeat service, Justfile
{ pkgs, lib, ... }:
let
  heartbeatScript = pkgs.writeShellApplication {
    name = "agent-heartbeat";
    runtimeInputs = [ pkgs.kubectl ];
    text = ''
      CLAIM_NAME="$(hostname)"
      NAMESPACE="workstations"
      export KUBECONFIG="/etc/workstation/kubeconfig"

      while true; do
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        kubectl annotate workspaceclaim "$CLAIM_NAME" \
          -n "$NAMESPACE" \
          --overwrite \
          "workstations.sammasak.dev/last-heartbeat-at=$ts" || true
        sleep 300
      done
    '';
  };
in
{
  home.packages = [ heartbeatScript ];

  # Seed ~/.claude.json on first boot so the interactive setup wizard is skipped.
  home.activation.seedClaudeState =
    let
      script = pkgs.writeShellScript "seed-claude-state" ''
        stateFile="$HOME/.claude.json"
        [ -f "$stateFile" ] && exit 0
        cat > "$stateFile" <<'SEED'
        {
          "numStartups": 1,
          "firstStartTime": "1970-01-01T00:00:00.000Z",
          "hasCompletedOnboarding": true,
          "lastOnboardingVersion": "2.0.0",
          "sonnet45MigrationComplete": true,
          "opus45MigrationComplete": true,
          "opusProMigrationComplete": true,
          "thinkingMigrationComplete": true,
          "hasShownOpus45Notice": {},
          "hasShownOpus46Notice": {},
          "projects": {
            "/home/lukas": {
              "hasTrustDialogAccepted": true,
              "projectOnboardingSeenCount": 1,
              "hasCompletedProjectOnboarding": true
            }
          }
        }
        SEED
        chmod 600 "$stateFile"
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # Headless agent: auto-approve all tool permissions (merged with shared settings)
  programs.claude-code.settings.permissions = {
    allow = [
      "Read"
      "Write"
      "Edit"
      "Bash"
      "Glob"
      "Grep"
      "WebFetch"
      "WebSearch"
    ];
    deny = [ ];
  };

  # Agent operations via Justfile
  home.file."Justfile".text = ''
    # Workstation agent operations
    # Usage: just agent "fix the bug in main.py"
    #        just agent-bg "refactor the test suite"

    set shell := ["bash", "-euo", "pipefail", "-c"]

    # Source workstation env files (API keys, OTEL config) and GitHub token
    _source-env := "[ -f /etc/workstation/agent-env ] && set -a && . /etc/workstation/agent-env && set +a; [ -f /etc/workstation/otel-env ] && set -a && . /etc/workstation/otel-env && set +a; _tf=\"''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/github-token\"; [ -f \"$_tf\" ] && export GH_TOKEN=\"$(cat \"$_tf\")\""

    # Run a headless Claude Code agent session (foreground, blocks until done)
    agent +prompt:
        #!/usr/bin/env bash
        set -euo pipefail
        {{ _source-env }}
        trap 'systemctl --user stop agent-heartbeat 2>/dev/null || true' EXIT
        systemctl --user start agent-heartbeat 2>/dev/null || true
        claude -p "{{prompt}}" --output-format json

    # Run agent in a background tmux session
    agent-bg +prompt:
        #!/usr/bin/env bash
        set -euo pipefail
        {{ _source-env }}
        if tmux has-session -t agent 2>/dev/null; then
            echo "Error: agent session already running. Use 'just agent-stop' first."
            exit 1
        fi
        systemctl --user start agent-heartbeat 2>/dev/null || true
        printf '%s\n' "{{prompt}}" > /tmp/.agent-prompt
        tmux new-session -d -s agent \
            "bash -c '{{ _source-env }}; claude -p \"\$(cat /tmp/.agent-prompt)\" --output-format json; rm -f /tmp/.agent-prompt; systemctl --user stop agent-heartbeat 2>/dev/null || true'"
        echo "Agent started in tmux session"
        echo "  attach:  tmux attach -t agent"
        echo "  stop:    just agent-stop"

    # Stop the running background agent
    agent-stop:
        #!/usr/bin/env bash
        tmux kill-session -t agent 2>/dev/null && echo "Agent session stopped." || echo "No agent session running."
        systemctl --user stop agent-heartbeat 2>/dev/null || true

    # Show agent and heartbeat status
    agent-status:
        #!/usr/bin/env bash
        echo "agent:"
        if tmux has-session -t agent 2>/dev/null; then
            echo "  running (tmux session: agent)"
        else
            echo "  not running"
        fi
        echo "heartbeat:"
        if systemctl --user is-active --quiet agent-heartbeat 2>/dev/null; then
            echo "  active"
        else
            echo "  inactive"
        fi

    # Tail recent heartbeat logs
    agent-logs:
        journalctl --user -u agent-heartbeat --no-pager -n 50
  '';

  # Systemd user service: heartbeat keeps the workspace alive during agent sessions
  systemd.user.services.agent-heartbeat = {
    Unit = {
      Description = "Annotate WorkspaceClaim to prevent idle shutdown during agent sessions";
    };
    Service = {
      Type = "simple";
      ExecStart = "${heartbeatScript}/bin/agent-heartbeat";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  # Fish: enable and source agent-env and otel-env in login profile.
  # ANTHROPIC_API_KEY is unset after sourcing: it is only for headless `just agent`
  # sessions (sourced again there via _source-env). Interactive Claude Code sessions
  # authenticate via CLAUDE_CODE_OAUTH_TOKEN instead.
  programs.fish.enable = true;
  programs.fish.loginShellInit = lib.mkAfter ''
    if test -f /etc/workstation/agent-env
      for line in (cat /etc/workstation/agent-env)
        if not string match -q '#*' $line
          and not string match -q 'ANTHROPIC_API_KEY=*' $line
          set -gx (string split -m 1 = $line)
        end
      end
    end
    if test -f /etc/workstation/otel-env
      for line in (cat /etc/workstation/otel-env)
        if not string match -q '#*' $line
          set -gx (string split -m 1 = $line)
        end
      end
    end
  '';
}
