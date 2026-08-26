# Git configuration
{ lib, osConfig ? null, ... }:
let
  resolvedUserConfig =
    if osConfig != null && osConfig ? sam && osConfig.sam ? userConfig then
      osConfig.sam.userConfig
    else
      { };
  gitConfig = resolvedUserConfig.git or { };
  gitUserName = gitConfig.userName or "Your Name";
  gitEmail = gitConfig.email or "you@example.com";
  # Workstation/worker VMs authenticate to GitHub over HTTPS with an app
  # token (github-app-auth) and have no SSH keys — the SSH rewrite below
  # must not apply there.
  isWorkstationVm =
    osConfig != null && (osConfig.homelab.workstation.enable or false);
in
{
  programs.git = {
    enable = true;
    settings = lib.mkMerge [
      {
        user.name = gitUserName;
        user.email = gitEmail;
        init.defaultBranch = "main";
        pull.rebase = true;
      }
      (lib.mkIf (!isWorkstationVm) {
        # Personal repos always go over SSH, even when referenced by HTTPS
        # URL — GitHub password auth is dead, so an HTTPS hit on a private
        # repo otherwise degrades into a doomed username/password prompt.
        url."git@github.com:sammasak/".insteadOf = "https://github.com/sammasak/";
      })
    ];
  };
}
