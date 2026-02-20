# Workstation image template (used for KubeVirt image builds).
{ pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ../../modules/homelab/workstation-image.nix
  ];

  sam.profile = vars;

  homelab.workstation.enable = true;

  # Embed static age identity so sops-nix can decrypt shared secrets at boot.
  # All VM instances share this key (accepted tradeoff for shared golden image).
  environment.etc."age/workstation-identity.key" = {
    source = ./age-identity.key;
    mode = "0400";
  };

  sops = {
    age = {
      sshKeyPaths = [];  # VMs have ephemeral SSH host keys; use embedded age key instead
      keyFile = "/etc/age/workstation-identity.key";
      generateKey = false;
    };
    secrets."claude_oauth_token" = {
      sopsFile = ../../secrets/claude/oauth.yaml;
      owner = vars.username;
      mode = "0400";
    };
  };

  # Home Manager configuration for workstation image template
  home-manager.users.${vars.username} = {
    home.stateVersion = "25.11";

    home.packages = [
      # Chromium for headless Playwright MCP use in Claude Code
      pkgs.chromium
      # Stub for the VS Code CLI — silences Claude Code's IDE detection check
      # (`which: no code in ...`) on headless VMs that have no VS Code installed.
      (pkgs.writeShellScriptBin "code" "exit 1")
    ];

    imports = [
      ../../modules/core/bash.nix
      ../../modules/core/starship.nix
      ../../modules/programs/cli/git
      ../../modules/programs/cli/cli-tools
      ../../modules/programs/cli/direnv
      ../../modules/programs/cli/claude-code
      ../../modules/programs/cli/github-app-auth
    ];
  };
}
