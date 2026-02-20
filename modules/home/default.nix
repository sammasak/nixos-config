# Shared Home Manager configuration for all NixOS hosts
{ lib, osConfig, ... }:
let
  profile = osConfig.sam.profile;
  roles = profile.roles;
  hasDesktop = builtins.elem "desktop" roles;
  baseImports = [
    ../core/bash.nix
    ../core/starship.nix
    ../programs/cli/git
    ../programs/cli/cli-tools
  ];
  desktopImports = lib.optionals hasDesktop [
    ../desktop/hyprland/home.nix
    ../programs/terminal/kitty
    ../programs/browser/firefox
    ../programs/editor/vscode
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;
}
