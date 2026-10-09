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

    # The HM module packages these into a generated `hm` plugin (a bundled
    # `.mcp.json`), so they load in every project — not via settings.json, which
    # Claude Code ignores for MCP. Mirrors the Codex playwright server: headless
    # chromium, --isolated so each session gets a fresh profile.
    mcpServers.playwright = {
      type = "stdio";
      command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
      args = [
        "--isolated"
        "--executable-path"
        "${pkgs.chromium}/bin/chromium"
        "--headless"
        "--sandbox"
      ];
    };

    # Interactive sibling of `playwright`: headed (a real window opens so you can
    # complete an interactive login, e.g. BankID). Use only when a task must act
    # as you on a logged-in site.
    # NOT --user-data-dir: playwright-mcp 0.0.80 is isolated-only and throws
    # "userDataDir is not supported in isolated mode" for it (and for a config
    # isolated:false). --storage-state is the supported persistence path — it
    # loads/saves cookies + localStorage, so the signed-in session survives
    # across Claude sessions.
    mcpServers."playwright-login" = {
      type = "stdio";
      command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
      args = [
        "--executable-path"
        "${pkgs.chromium}/bin/chromium"
        "--storage-state"
        "${config.home.homeDirectory}/.local/share/claude-playwright-login/state.json"
        "--sandbox"
      ];
    };

    settings = {
      theme = "dark";
      model = "claude-opus-5-5";
      # Answers the "Try the new fullscreen renderer?" startup prompt; the
      # read-only settings.json means the interactive choice can never save.
      tui = "fullscreen";
      env = {
        DISABLE_TELEMETRY = "1";
        DISABLE_ERROR_REPORTING = "1";
      };
      enabledPlugins = {
        "superpowers@claude-plugins-official" = true;
        # Declaratively enabled so they persist: the generated settings.json is
        # read-only, so interactive `/plugin` toggles cannot save. Both
        # marketplaces are already known, so no marketplace declaration is needed.
        "rust-analyzer-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
      };
      # Hook commands are Nix store paths from the claude-code-skills input, so
      # they resolve on every host regardless of HOME.
      hooks = {
        Stop = [{
          hooks = [
            {
              type = "command";
              command = "${skillsSrc}/hooks/check-git-state.sh";
              timeout = 10;
            }
          ];
        }];
        PreToolUse = [
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
            {
              type = "command";
              command = "${skillsSrc}/hooks/validate-nix.sh";
            }
            {
              # PATH prefix: shellcheck is not in the user environment, and the
              # hook skips silently when it cannot find the binary.
              type = "command";
              command = "PATH=${lib.makeBinPath [ pkgs.shellcheck ]}:$PATH ${skillsSrc}/hooks/validate-shell.sh";
            }
          ];
        }];
      };
    };
  };

  # playwright-login writes its --storage-state here; playwright-mcp does not
  # create the parent dir, so ensure it exists.
  home.file.".local/share/claude-playwright-login/.keep".text = "";

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
