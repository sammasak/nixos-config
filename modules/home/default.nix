# Shared Home Manager configuration for all NixOS hosts
{ lib, osConfig, ... }:
let
  isDesktopMode = osConfig.sam.desktop.enable or false;
  hasDevTools = osConfig.sam.profile.devTools;
  baseImports = [
    ../core/fish.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
    ../programs/cli/direnv
  ];
  devToolImports = lib.optionals hasDevTools [
    ../programs/cli/dev-init
    ../programs/cli/flake-update
    ../programs/cli/repo-sweep
    ../programs/cli/herdr
    ../programs/editor/nvim
    ./pi-harness
  ];
  desktopImports = lib.optionals isDesktopMode [
    ../desktop/common/home.nix
    ../desktop/niri/home.nix
    ../programs/cli/comma
    ../programs/cli/dev-tools
    ../programs/cli/tui
    ../programs/terminal/ghostty
    ../programs/browser/firefox
    ../programs/gui/viewers
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ devToolImports ++ desktopImports;
}
