# Claude Code shared configuration — settings, plugins, MCP servers, NixOS fixes
#
# Injected into every host via home-manager.sharedModules in 40-outputs-nixos.nix.
# Uses the upstream programs.claude-code Home Manager module.
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
    };

    # MCP servers at top-level for auto-discovery
    mcpServers = {
      playwright = {
        command = "sh";
        args = [
          "-c"
          ''exec npx @playwright/mcp@latest --headless --browser chromium --executable-path "$(which chromium)"''
        ];
      };
    };
  };

  # ── OAuth token sourcing ────────────────────────────────────────────
  # All hosts (physical + VM golden image) get the token from sops-nix at
  # /run/secrets/claude_oauth_token. ~/.env is a manual fallback only.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -f "$HOME/.env"
      and grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" 2>/dev/null
      set -gx CLAUDE_CODE_OAUTH_TOKEN (grep '^CLAUDE_CODE_OAUTH_TOKEN=' "$HOME/.env" | cut -d= -f2-)
    end
    if test -f /run/secrets/claude_oauth_token
      set -gx CLAUDE_CODE_OAUTH_TOKEN (cat /run/secrets/claude_oauth_token)
    end
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
