{ pkgs, ... }:
{
  # Mirrors the starship prompt (directory, git branch) plus model and context use.
  programs.claude-code.settings.statusLine = {
    type = "command";
    command = toString (
      pkgs.writeShellScript "claude-statusline" ''
        input=$(cat)
        jq=${pkgs.jq}/bin/jq
        dir=$(echo "$input" | $jq -r '.workspace.current_dir // .cwd')
        model=$(echo "$input" | $jq -r '.model.display_name')
        used=$(echo "$input" | $jq -r '.context_window.used_percentage // empty')
        br=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" symbolic-ref --short HEAD 2>/dev/null \
          || GIT_OPTIONAL_LOCKS=0 git -C "$dir" rev-parse --short HEAD 2>/dev/null)
        printf '\033[36m%s\033[0m' "''${dir/#$HOME/\~}"
        [ -n "$br" ] && printf ' on \033[35m%s\033[0m' "$br"
        printf ' \033[2m%s\033[0m' "$model"
        [ -n "$used" ] && printf ' \033[33mctx %.0f%%\033[0m' "$used"
        echo
      ''
    );
  };

  # Auto-approve with destructive classes carved out: deny wins over allow,
  # and a denied call is refused outright (deny rules never prompt).
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
      # Prefix-only coarse backstop; cleverer spellings and all fs deletion
      # (deny cannot be approved, and a root-rm prefix refuses legit deep deletes) are validate-bash's.
      "Bash(git push --force:*)"
      "Bash(git push -f:*)"
      "Bash(git push --no-verify:*)"
      "Bash(kubectl delete pv:*)"
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
