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

  # The Claude OAuth token is delivered to VM instances at boot via cloud-init
  # (/etc/workstation/agent-env), sourced in the fish login shell by
  # modules/programs/cli/claude-code/default.nix. No static age key is embedded.

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
