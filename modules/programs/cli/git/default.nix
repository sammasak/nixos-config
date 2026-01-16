# Git configuration
{ userConfig ? {}, ... }:
let
  gitConfig = userConfig.git or {};
  gitUserName = gitConfig.userName or "Your Name";
  gitEmail = gitConfig.email or "you@example.com";
in
{
  programs.git = {
    enable = true;
    settings = {
      user.name = gitUserName;
      user.email = gitEmail;
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };
}
