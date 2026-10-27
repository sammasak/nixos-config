{ osConfig ? null, ... }:
let
  resolvedUserConfig =
    if osConfig != null && osConfig ? sam && osConfig.sam ? userConfig then
      osConfig.sam.userConfig
    else
      { };
  gitConfig = resolvedUserConfig.git or { };
  gitUserName = gitConfig.userName or "Your Name";
  gitEmail = gitConfig.email or "you@example.com";
in
{
  # Global by structural necessity: gitconfig references the diff binary from
  # any directory, devshell or not. `git diff --no-ext-diff` for plain output.
  programs.difftastic = {
    enable = true;
    git.enable = true;
    git.mode = "external";
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = gitUserName;
      user.email = gitEmail;
      init.defaultBranch = "main";
      pull.rebase = true;

      # Personal repos always go over SSH, even when referenced by HTTPS URL —
      # GitHub password auth is dead, so an HTTPS hit on a private repo
      # otherwise degrades into a doomed username/password prompt.
      url."git@github.com:sammasak/".insteadOf = "https://github.com/sammasak/";
    };
  };
}
