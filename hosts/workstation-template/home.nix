# Home Manager profile for workstation image template.
{ ... }:
{
  home.stateVersion = "25.11";

  imports = [
    ../../modules/core/nushell.nix
    ../../modules/core/starship.nix
    ../../modules/programs/cli/git
    ../../modules/programs/cli/cli-tools
    ../../modules/programs/cli/direnv
    ../../modules/programs/cli/claude-code
  ];
}
