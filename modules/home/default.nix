# Shared Home Manager configuration for all NixOS hosts
{ lib, osConfig, ... }:
let
  isDesktopMode = osConfig.sam.desktop.enable or false;
  baseImports = [
    ../core/fish.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
    ../programs/cli/direnv
    ../programs/cli/dev-init
    ../programs/cli/flake-update
    ../programs/cli/herdr
    ../programs/editor/nvim
  ];
  desktopImports = lib.optionals isDesktopMode [
    ../desktop/hyprland/home.nix
    ../desktop/niri/home.nix
    ../programs/cli/comma
    ../programs/cli/dev-tools
    ../programs/cli/tui
    ../programs/terminal/kitty
    ../programs/browser/firefox
    ../programs/editor/vscode
    ../programs/gui/obsidian
    ../programs/gui/viewers
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;
}
