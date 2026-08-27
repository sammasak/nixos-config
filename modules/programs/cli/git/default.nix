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
      #
      # This used to be skipped on the workstation/worker VM images, which
      # authenticated over HTTPS with a GitHub App token and had no SSH keys.
      # Those images were retired with the KubeVirt platform; every remaining
      # host is a physical machine with SSH keys, so the rewrite is unconditional.
      url."git@github.com:sammasak/".insteadOf = "https://github.com/sammasak/";
    };
  };
}
