# Server profile - CLI-only environment
# Same shell experience as desktop, no GUI
#
# User: nushell, starship, git, CLI tools

{ user, ... }:
{
  # === USER-LEVEL (home-manager) ===

  home-manager.users.${user} = {
    home.username = user;
    home.homeDirectory = "/home/${user}";
    home.stateVersion = "25.11";

    imports = [
      ../modules/shell/nushell.nix
      ../modules/shell/starship.nix
      ../modules/shell/git.nix
      ../modules/shell/cli-tools.nix
    ];
  };
}
