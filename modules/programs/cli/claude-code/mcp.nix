# Claude Code settings, plugins and NixOS fixes, injected into every host via
# home-manager.sharedModules. Takes the claude-code-skills flake input as its
# first argument, so it is imported applied:
#   (import .../claude-code/mcp.nix inputs.claude-code-skills)
skillsSrc:
{ pkgs, lib, config, ... }:
{
  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code;

    settings = {
      theme = "dark";
      model = "claude-opus-4-8";
      env = {
        DISABLE_TELEMETRY = "1";
        DISABLE_ERROR_REPORTING = "1";
      };
      enabledPlugins = {
        "ralph-loop@claude-plugins-official" = true;
        "superpowers@claude-plugins-official" = true;
        "superpowers-lab@superpowers-marketplace" = true;
        # Declaratively enabled so they persist: the generated settings.json is
        # read-only, so interactive `/plugin` toggles cannot save. Both
        # marketplaces are already known, so no marketplace declaration is needed.
        "rust-analyzer-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
        "context7@claude-plugins-official" = true;
      };
      # No `mcpServers` here: Claude Code ignores it in settings.json and reads
      # MCP servers only from a project `.mcp.json`, `~/.claude.json`, or
      # --mcp-config. Add servers per project.
      #
      # Hook commands are Nix store paths from the claude-code-skills input, so
      # they resolve on every host regardless of HOME.
      hooks = {
        UserPromptSubmit = [{
          hooks = [{
            type = "command";
            command = "${skillsSrc}/hooks/retrieve-context.sh";
            timeout = 15;
          }];
        }];
        Stop = [{
          hooks = [
            {
              type = "command";
              command = "${skillsSrc}/hooks/persist-session.sh";
              timeout = 45;
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/extract-instincts.sh";
              timeout = 45;
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/check-goals.sh";
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/write-session-state.sh";
              timeout = 45;
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/agent-telemetry.sh";
              timeout = 60;
            }
          ];
        }];
        PreToolUse = [
          {
            matcher = "Bash|Write|Edit|MultiEdit";
            hooks = [{
              type = "command";
              command = "${skillsSrc}/hooks/report-activity.sh";
            }];
          }
          {
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
          }
        ];
        PostToolUse = [{
          matcher = "Write|Edit";
          hooks = [
            {
              type = "command";
              command = "${skillsSrc}/hooks/validate-manifest.sh";
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/validate-rust.sh";
            }
          ];
        }];
      };
    };
  };

  # ── OAuth token sourcing ────────────────────────────────────────────
  # sops-nix decrypts the token to /run/secrets/claude_oauth_token at boot
  # (declared by modules/core/sops.nix). The path is a literal here on purpose:
  # this is a Home Manager module, so `config` is the HM configuration and
  # `config.sops.secrets` — a NixOS option — is not in scope.
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
