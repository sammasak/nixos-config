{ ... }:
{
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
