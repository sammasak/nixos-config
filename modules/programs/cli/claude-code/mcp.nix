# Claude Code shared configuration — settings, plugins, MCP servers, NixOS fixes
#
# Injected into every host via home-manager.sharedModules in 40-outputs-nixos.nix.
# Uses the upstream programs.claude-code Home Manager module.
#
# Usage (in 40-outputs-nixos.nix):
#   (import ../modules/programs/cli/claude-code/mcp.nix inputs.claude-code-skills)
#
# Hooks are wired via Nix store paths so they are available on all hosts,
# including claude-worker VMs where HOME=/var/lib/claude-worker.
skillsSrc:
{ pkgs, lib, config, ... }:
{
  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code;

    settings = {
      theme = "dark";
      env = {
        DISABLE_TELEMETRY = "1";
        DISABLE_ERROR_REPORTING = "1";
      };
      enabledPlugins = {
        "ralph-loop@claude-plugins-official" = true;
        "superpowers@claude-plugins-official" = true;
        "playwright@claude-plugins-official" = true;
        "superpowers-lab@superpowers-marketplace" = true;
      };
      # MCP servers in settings.json instead of the top-level mcpServers option,
      # which creates a wrapper that appends --mcp-config to every invocation and
      # breaks subcommands like `claude setup-token`.
      mcpServers = {
        playwright = {
          type = "stdio";
          command = "${pkgs.playwright-mcp}/bin/mcp-server-playwright";
          args = [];
        };
      };
      # Hooks are wired from the claude-code-skills Nix store path so they are
      # available everywhere: physical hosts, workstation VMs, and claude-worker VMs.
      # check-goals.sh no-ops on physical hosts (goals.json absent).
      # validate-bash.sh has a VM guard for agent-specific rules.
      # validate-manifest.sh works on all hosts.
      hooks = {
        Stop = [{
          hooks = [{
            type = "command";
            command = "${skillsSrc}/hooks/check-goals.sh";
          }];
        }];
        PreToolUse = [{
          matcher = "Bash";
          hooks = [
            {
              type = "command";
              command = "${skillsSrc}/hooks/validate-bash.sh";
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/check-loop.sh";
            }
          ];
        }];
        PostToolUse = [{
          matcher = "Write|Edit";
          hooks = [{
            type = "command";
            command = "${skillsSrc}/hooks/validate-manifest.sh";
          }];
        }];
      };
    };
  };

  # ── OAuth token sourcing ────────────────────────────────────────────
  # Physical hosts: sops-nix decrypts the token to /run/secrets/claude_oauth_token at boot.
  # VM golden images: token delivered via cloud-init (/etc/workstation/agent-env),
  #   sourced in fish loginShellInit by modules/programs/cli/claude-code/default.nix.
  # ~/.env: local development override only.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f "$HOME/.env"
      and grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" 2>/dev/null
      set -gx CLAUDE_CODE_OAUTH_TOKEN (grep '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" | cut -d= -f2-)
    end
    if test -f /run/secrets/claude_oauth_token
      set -gx CLAUDE_CODE_OAUTH_TOKEN (cat /run/secrets/claude_oauth_token)
    end
  '';

  # ── Claude state: suppress interactive startup dialogs ──────────────
  # 1. bypassPermissionsModeAccepted — skips the "WARNING: Bypass Permissions
  #    mode" dialog shown on every `claude --dangerously-skip-permissions` launch.
  # 2. projects[$HOME].hasTrustDialogAccepted — skips the "Is this a project
  #    you trust?" dialog for $HOME and all subdirectories (tree-walk in Ew()).
  home.activation.acceptClaudeStartupDialogs =
    let
      script = pkgs.writeShellScript "accept-claude-startup-dialogs" ''
        stateFile="$HOME/.claude.json"
        if [ ! -f "$stateFile" ]; then
          echo '{}' > "$stateFile"
          chmod 600 "$stateFile"
        fi
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT
        chmod 600 "$tmp"
        ${pkgs.jq}/bin/jq \
          --arg home "$HOME" \
          '.bypassPermissionsModeAccepted = true | .projects[$home].hasTrustDialogAccepted = true' \
          "$stateFile" > "$tmp" && mv "$tmp" "$stateFile"
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # ── NixOS shebang fixes ──────────────────────────────────────────────
  # Patches #!/bin/bash → #!/usr/bin/env bash in plugin cache.
  # NixOS doesn't have /bin/bash; re-runs on rebuild to fix new/updated plugins.
  home.activation.fixClaudePluginShebangs =
    let
      script = pkgs.writeShellScript "fix-claude-plugin-shebangs" ''
        pluginDir="$HOME/.claude/plugins/cache"
        [ -d "$pluginDir" ] || exit 0
        find "$pluginDir" -name '*.sh' -type f | while read -r f; do
          head -1 "$f" | grep -qF '#!/bin/bash' && ${pkgs.gnused}/bin/sed -i '1s|^#!/bin/bash|#!/usr/bin/env bash|' "$f" || true
        done
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';
}
