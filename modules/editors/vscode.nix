# Visual Studio Code
# Uses home-manager for per-user configuration

{ pkgs, ... }:
{
  programs.vscode = {
    enable = true;
    # Extensions and settings can be added here
    # extensions = with pkgs.vscode-extensions; [
    #   jnoortheen.nix-ide
    #   esbenp.prettier-vscode
    # ];
  };
}
