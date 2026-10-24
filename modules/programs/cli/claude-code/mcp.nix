# Claude Code settings, plugins and NixOS fixes, injected into every host via
# home-manager.sharedModules. Takes the skills flake input as its
# first argument, so it is imported applied:
#   (import .../claude-code/mcp.nix inputs.skills)
skillsSrc: nativeOtel: hostName:
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
        DISABLE_ERROR_REPORTING = "1";
      } // lib.optionalAttrs (!nativeOtel) {
        DISABLE_TELEMETRY = "1";
      } // lib.optionalAttrs nativeOtel {
        CLAUDE_CODE_ENABLE_TELEMETRY = "1";
        CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = "1";
        OTEL_METRICS_EXPORTER = "otlp";
        OTEL_LOGS_EXPORTER = "otlp";
        OTEL_EXPORTER_OTLP_ENDPOINT = "https://otlp.sammasak.dev";
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
        OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE = "cumulative";
        OTEL_RESOURCE_ATTRIBUTES = "host.name=${lib.toLower hostName}";
        OTEL_METRICS_INCLUDE_SESSION_ID = "false";
        OTEL_METRICS_INCLUDE_ACCOUNT_UUID = "false";
        OTEL_LOG_USER_PROMPTS = "0";
        OTEL_LOG_TOOL_CONTENT = "0";
        OTEL_LOG_TOOL_DETAILS = "0";
        OTEL_LOG_RAW_API_BODIES = "0";
      };
      enabledPlugins = {
        # The complete intended set — anything not listed here is uninstalled.
        # Declared here because interactive `/plugin` toggles cannot save
        # against the read-only settings.json.
        "superpowers@claude-plugins-official" = true;
        "rust-analyzer-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
        # usageCount 2006 in ~/.claude.json: pruning it fought real daily use
        # (slash-command usage is invisible to Skill-invocation greps).
        "ralph-loop@claude-plugins-official" = true;
      };
      # Hook commands are Nix store paths from the skills input, so
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
            # 15s: these run before EVERY Bash call. p99 is ~0.8s but under
            # high load avg the ~74 sed/grep forks have hit 3.7s; a timed-out
            # PreToolUse hook does NOT block, so the budget must clear the
            # worst case with headroom rather than fail-open the guard.
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${skillsSrc}/hooks/validate-bash.sh";
                timeout = 15;
              }
              {
                type = "command";
                command = "${skillsSrc}/hooks/check-loop.sh";
                timeout = 15;
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
              timeout = 30;
            }
            {
              type = "command";
              command = "${skillsSrc}/hooks/validate-nix.sh";
              timeout = 30;
            }
            {
              # PATH prefix: shellcheck is not in the user environment, and the
              # hook skips silently when it cannot find the binary.
              type = "command";
              command = "PATH=${lib.makeBinPath [ pkgs.shellcheck ]}:$PATH ${skillsSrc}/hooks/validate-shell.sh";
              timeout = 30;
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
          # Convergence is prune-only; installing needs an interactive /plugin
          # run, so a declared-but-missing plugin gets a loud line instead.
          # Marketplace-served plugins never enter installed_plugins.json, so
          # presence under marketplaces/*/plugins/ also counts as installed.
          for p in ${lib.concatStringsSep " " (map (p: lib.head (lib.splitString "@" p)) declared)}; do
            ${pkgs.jq}/bin/jq -e --arg p "$p" '.plugins | keys | map(split("@")[0]) | index($p)' \
              "$base/installed_plugins.json" >/dev/null 2>&1 && continue
            ls -d "$base"/marketplaces/*/plugins/"$p" >/dev/null 2>&1 && continue
            ls -d "$base"/marketplaces/*/"$p" >/dev/null 2>&1 && continue
            echo "claude-code: declared plugin '$p' is not installed — run /plugin install" >&2
          done
        fi
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # Live sessions keep enforcing the hook generation loaded at their start,
  # and the in-band Stop-hook warning only exists in NEW generations — so a
  # generation change also pings ntfy out-of-band (fail-open: no LAN, no ping).
  home.activation.notifyHookGeneration =
    let
      script = pkgs.writeShellScript "notify-hook-generation" ''
        state="$HOME/.local/state/claude-hooks/deployed-store"
        [ "$(cat "$state" 2>/dev/null)" = "${skillsSrc}" ] && exit 0
        mkdir -p "$(dirname "$state")"
        printf '%s' "${skillsSrc}" > "$state"
        ${pkgs.curl}/bin/curl -fsS -m 5 \
          -H "Title: Claude hooks updated" -H "Priority: min" -H "Tags: wrench" \
          -d "New hook generation ${skillsSrc} deployed; running Claude sessions enforce their start-time generation until restarted." \
          https://ntfy.sammasak.dev/homelab-improvements >/dev/null 2>&1 || true
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';

  # The four manual-.githooks repos carry the no-force guard only when
  # core.hooksPath=.githooks is set, and that config does NOT travel with a
  # clone — a fresh checkout runs no guard until set. Every machine runs HM
  # activation, so set it here for each repo that exists with a .githooks dir:
  # a fresh clone is guarded by its first rebuild. Idempotent, skips absent repos.
  home.activation.wireManualGitHooks =
    let
      wireScript = pkgs.writeShellScript "wire-manual-githooks" ''
        for r in nixos-config skills homelab-gitops knowledge; do
          d="$HOME/$r"
          [ -d "$d/.git" ] && [ -d "$d/.githooks" ] || continue
          cur=$(${pkgs.git}/bin/git -C "$d" config --local core.hooksPath 2>/dev/null || true)
          [ "$cur" = ".githooks" ] && continue
          ${pkgs.git}/bin/git -C "$d" config --local core.hooksPath .githooks || true
        done
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${wireScript}
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
