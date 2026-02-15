# Home Manager configuration for msi-ms7758
{ lib, osConfig, ... }:
let
  profile = osConfig.sam.profile;
  roles = profile.roles;
  hasDesktop = builtins.elem "desktop" roles;
  baseImports = [
    ../../modules/core/nushell.nix
    ../../modules/core/starship.nix
    ../../modules/programs/cli/git
    ../../modules/programs/cli/cli-tools
  ];
  desktopImports = lib.optionals hasDesktop [
    ../../modules/desktop/${profile.desktop}/home.nix
    ../../modules/programs/terminal/${profile.terminal}
    ../../modules/programs/browser/${profile.browser}
    ../../modules/programs/editor/${profile.editor}
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;
}
