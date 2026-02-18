# Home configuration for lukas (darwin CLI)
{ ... }:
{
  home.stateVersion = "25.11";

  imports = [
    ../modules/core/bash.nix
    ../modules/core/starship.nix
    ../modules/programs/cli/git
    ../modules/programs/cli/cli-tools
    ../modules/programs/editor/vscode
  ];
}
