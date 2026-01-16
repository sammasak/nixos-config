# Home Manager configuration for lenovo-21CB001PMX
{ lib, host, userConfig ? {}, ... }:
let
  vars = import ./variables.nix;
  roles = vars.roles or [ "base" "desktop" "laptop" ];
  hasDesktop = builtins.elem "desktop" roles;
  baseImports = [
    ../../modules/core/nushell.nix
    ../../modules/core/starship.nix
    ../../modules/programs/cli/git
    ../../modules/programs/cli/cli-tools
  ];
  desktopImports = lib.optionals hasDesktop [
    ../../modules/desktop/${vars.desktop}/home.nix
    ../../modules/programs/terminal/${vars.terminal}
    ../../modules/programs/browser/${vars.browser}
    ../../modules/programs/editor/${vars.editor}
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;
}
