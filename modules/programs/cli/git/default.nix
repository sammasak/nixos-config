{ osConfig, ... }:
let
  inherit (osConfig.sam.userConfig) git;
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
      user.name = git.userName;
      user.email = git.email;
      init.defaultBranch = "main";
      pull.rebase = true;

      # Personal repos always go over SSH, even when referenced by HTTPS URL —
      # GitHub password auth is dead, so an HTTPS hit on a private repo
      # otherwise degrades into a doomed username/password prompt.
      url."git@github.com:sammasak/".insteadOf = "https://github.com/sammasak/";
    };
  };
}
