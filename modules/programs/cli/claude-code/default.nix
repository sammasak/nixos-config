# Claude Code agent configuration — first-boot state seed + tool permissions
{ pkgs, lib, osConfig, ... }:
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

  # Auto-approve tool permissions (merged with shared settings), with the
  # destructive classes carved out: deny wins over allow, so these prompt or
  # fail even in bypass-permissions sessions. validate-bash.sh backstops the
  # same classes in-session.
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
    deny = [
      "Bash(git push --force:*)"
      "Bash(git push -f:*)"
      "Bash(rm -rf /:*)"
      "Bash(kubectl delete pvc:*)"
      "Bash(kubectl delete namespace:*)"
      "Bash(kubectl delete ns:*)"
    ];
  };

  # Enabled here because the sibling Claude Code / Codex Home Manager modules
  # attach interactiveShellInit fragments to it.
  programs.fish.enable = true;

  # Bound agent sessions on both laptops so coding tools remain useful without
  # allowing an agent or build to make the interactive desktop unusable.
  programs.fish.functions = {
    agent-run = ''
      set -l command $argv[1]
      set -e argv[1]
      systemd-run --user --scope --quiet \
        -p CPUWeight=50 -p CPUQuota=400% -p MemoryHigh=4G -p MemoryMax=5G \
        -p IOWeight=50 -- $command $argv
    '';
    ccap = ''
      agent-run claude $argv
    '';
    codexcap = ''
      agent-run codex $argv
    '';
  };
}
