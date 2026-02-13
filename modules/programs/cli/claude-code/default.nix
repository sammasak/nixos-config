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

  # Default agent permissions for headless operation
  home.file.".claude/settings.json".text = builtins.toJSON {
    permissions = {
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
  };

  # Agent operations via Justfile
  home.file."Justfile".text = ''
    # Workstation agent operations
    # Usage: just agent "fix the bug in main.py"
    #        just agent-bg "refactor the test suite"

    set shell := ["bash", "-euo", "pipefail", "-c"]

    # Run a headless Claude Code agent session (foreground, blocks until done)
    agent +prompt:
        #!/usr/bin/env bash
        set -euo pipefail
        trap 'systemctl --user stop agent-heartbeat 2>/dev/null || true' EXIT
        systemctl --user start agent-heartbeat 2>/dev/null || true
        claude -p "{{prompt}}" --output-format json

    # Run agent in a background tmux session
    agent-bg +prompt:
        #!/usr/bin/env bash
        set -euo pipefail
        if tmux has-session -t agent 2>/dev/null; then
            echo "Error: agent session already running. Use 'just agent-stop' first."
            exit 1
        fi
        systemctl --user start agent-heartbeat 2>/dev/null || true
        printf '%s\n' "{{prompt}}" > /tmp/.agent-prompt
        tmux new-session -d -s agent \
            'claude -p "$(cat /tmp/.agent-prompt)" --output-format json; rm -f /tmp/.agent-prompt; systemctl --user stop agent-heartbeat 2>/dev/null || true'
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

  # Bash: enable and source agent-env and otel-env
  programs.bash.enable = true;
  programs.bash.initExtra = lib.mkAfter ''
    [ -f /etc/workstation/agent-env ] && set -a && . /etc/workstation/agent-env && set +a
    [ -f /etc/workstation/otel-env ] && set -a && . /etc/workstation/otel-env && set +a
  '';

  # Nushell: load the same env files via load-env
  programs.nushell.extraEnv = ''
    for file in ["/etc/workstation/agent-env" "/etc/workstation/otel-env"] {
      if ($file | path exists) {
        open $file
          | lines
          | where { |line| ($line | str trim | str length) > 0 and not ($line | str starts-with "#") }
          | each { |line|
            let parts = ($line | split column "=" key value)
            { ($parts.0.key | str trim): ($parts.0.value | str trim) }
          }
          | reduce --fold {} { |it, acc| $acc | merge $it }
          | load-env
      }
    }
  '';
}
