# Shared Home Manager configuration for all NixOS hosts
{ lib, osConfig, ... }:
let
  profile = osConfig.sam.profile;
  isDesktopMode = osConfig.programs.hyprland.enable or false;
  baseImports = [
    ../core/fish.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
    ../programs/editor/nvim
  ];
  desktopImports = lib.optionals isDesktopMode [
    ../desktop/hyprland/home.nix
    ../programs/terminal/kitty
    ../programs/browser/firefox
    ../programs/editor/vscode
    ../programs/gui/obsidian
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;
}
