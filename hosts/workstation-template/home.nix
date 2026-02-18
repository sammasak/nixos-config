# Home Manager profile for workstation image template.
{ pkgs, ... }:
{
  home.stateVersion = "25.11";

  # Chromium for headless Playwright MCP use in Claude Code
  home.packages = [ pkgs.chromium ];

  imports = [
    ../../modules/core/nushell.nix
    ../../modules/core/starship.nix
    ../../modules/programs/cli/git
    ../../modules/programs/cli/cli-tools
    ../../modules/programs/cli/direnv
    ../../modules/programs/cli/claude-code
  ];
}
