# Claude Code shared configuration — settings, plugins, MCP servers, NixOS fixes
#
# Injected into every host via home-manager.sharedModules in 40-outputs-nixos.nix.
# Uses the upstream programs.claude-code Home Manager module.
{ pkgs, lib, ... }:
{
  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code; # needed for MCP wrapper; also in system packages

    settings = {
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

    mcpServers = {
      playwright = {
        command = "sh";
        args = [
          "-c"
          ''exec npx @playwright/mcp@latest --browser chromium --executable-path "$(which chromium)"''
        ];
      };
    };
  };

  # ── NixOS shebang fixes ──────────────────────────────────────────────
  # Patches #!/bin/bash → #!/usr/bin/env bash in plugin cache.
  # NixOS doesn't have /bin/bash; re-runs on rebuild to fix new/updated plugins.
  home.activation.fixClaudePluginShebangs =
    let
      script = pkgs.writeShellScript "fix-claude-plugin-shebangs" ''
        pluginDir="$HOME/.claude/plugins/cache"
        [ -d "$pluginDir" ] || exit 0
        find "$pluginDir" -name '*.sh' -type f | while read -r f; do
          head -1 "$f" | grep -q '^#!/bin/bash' && ${pkgs.gnused}/bin/sed -i '1s|^#!/bin/bash|#!/usr/bin/env bash|' "$f"
        done
      '';
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${script}
    '';
}
