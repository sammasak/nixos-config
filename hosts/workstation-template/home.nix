# Home Manager profile for workstation image template.
{ pkgs, ... }:
{
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
}
