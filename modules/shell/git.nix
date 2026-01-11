# Git configuration
# Credentials passed via userConfig from flake.nix
{ userConfig ? {}, ... }:
let
  gitConfig = userConfig.git or {};
  gitUserName = gitConfig.userName or "Your Name";
  gitEmail = gitConfig.email or "you@example.com";
in
{
  programs.git = {
    enable = true;
    userName = gitUserName;
    userEmail = gitEmail;
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };
}
