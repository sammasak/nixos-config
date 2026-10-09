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

    # Delivered via the HM-generated plugin bundle: Claude Code ignores MCP
    # servers declared in settings.json.
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

    # Headed sibling for interactive logins (e.g. BankID). --storage-state, NOT
    # --user-data-dir: playwright-mcp 0.0.80 is isolated-only and throws on the
    # latter; storage-state persists the signed-in session across Claude sessions.
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
      # Pre-answered: read-only settings.json means the prompt could never save.
      tui = "fullscreen";
      env = {
        DISABLE_TELEMETRY = "1";
        DISABLE_ERROR_REPORTING = "1";
      };
      enabledPlugins = {
        # The complete intended set — anything not listed here is uninstalled.
        # Declared here because interactive `/plugin` toggles cannot save
        # against the read-only settings.json.
        "superpowers@claude-plugins-official" = true;
        "rust-analyzer-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
        "code-simplifier@claude-plugins-official" = true;
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
              # cargo check on a cold workspace can exceed the default 60s;
              # an explicit budget keeps the death visible in the hook log.
              type = "command";
              command = "${skillsSrc}/hooks/validate-rust.sh";
              timeout = 120;
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

  # playwright-mcp does not create the --storage-state parent dir itself.
  home.file.".local/share/claude-playwright-login/.keep".text = "";

  # Keeps the enabledPlugins declaration true on disk: interactive /plugin
  # installs survive in mutable ~/.claude/plugins state, so anything not
  # declared is pruned from cache, data, and the installed list on activation.
  home.activation.prunePluginState =
    let
      declared = lib.attrNames config.programs.claude-code.settings.enabledPlugins;
      keep = lib.concatStringsSep "|" (map (p: lib.head (lib.splitString "@" p)) declared);
      keepMarketplaces = lib.concatStringsSep "|" (
        lib.unique (map (p: lib.last (lib.splitString "@" p)) declared)
      );
      script = pkgs.writeShellScript "prune-plugin-state" ''
        base="$HOME/.claude/plugins"
        [ -d "$base/cache" ] || exit 0
        for dir in "$base"/cache/*/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keep})$' && continue
          rm -rf "$dir"
        done
        for dir in "$base"/data/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keep})' || rm -rf "$dir"
        done
        rmdir "$base"/cache/*/ 2>/dev/null || true
        for dir in "$base"/marketplaces/*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          echo "$name" | grep -qE '^(${keepMarketplaces})$' || rm -rf "$dir"
        done
        if [ -f "$base/known_marketplaces.json" ]; then
          ${pkgs.jq}/bin/jq --arg keep '${keepMarketplaces}' \
            'with_entries(select(.key | test("^(" + $keep + ")$")))' \
            "$base/known_marketplaces.json" > "$base/.km.tmp" && mv "$base/.km.tmp" "$base/known_marketplaces.json"
        fi
        if [ -f "$base/installed_plugins.json" ]; then
          ${pkgs.jq}/bin/jq --arg keep '${keep}' \
            '.plugins |= with_entries(select(.key | split("@")[0] | test("^(" + $keep + ")$")))' \
            "$base/installed_plugins.json" > "$base/.ipj.tmp" && mv "$base/.ipj.tmp" "$base/installed_plugins.json"
        fi
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # sops-nix decrypts to /run/secrets/claude_oauth_token (modules/core/sops.nix).
  # Literal path on purpose: this is an HM module, so config.sops.secrets — a
  # NixOS option — is not in scope. ~/.env is a local dev override only.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f "$HOME/.env"
      and grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" 2>/dev/null
      set -gx CLAUDE_CODE_OAUTH_TOKEN (grep '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" | cut -d= -f2-)
    end
    if test -f /run/secrets/claude_oauth_token
      set -gx CLAUDE_CODE_OAUTH_TOKEN (cat /run/secrets/claude_oauth_token)
    end
  '';

  # Pre-accepts the bypass-permissions and $HOME project-trust dialogs, which
  # would otherwise reappear every launch (read-only settings.json).
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
