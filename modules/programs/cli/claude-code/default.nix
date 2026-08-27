# Claude Code agent configuration — first-boot state seed + tool permissions
{ pkgs, lib, ... }:
{
  # Seed ~/.claude.json on first boot so the interactive setup wizard is skipped.
  # NOTE: the project path "/home/lukas" is hardcoded in the JSON. This module
  # is applied to every host via `sharedModules`, and every host uses "lukas".
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
          "bypassPermissionsModeAccepted": true,
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

  # Enabled here because the sibling Claude Code / Codex Home Manager modules
  # attach interactiveShellInit fragments to it.
  programs.fish.enable = true;
}
