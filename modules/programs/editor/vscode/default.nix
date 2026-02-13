# Visual Studio Code
{ pkgs, ... }:
let
  configDir = if pkgs.stdenv.isDarwin
    then "Library/Application Support/Code/User"
    else ".config/Code/User";
  vscodePkgs = import (builtins.getFlake "github:NixOS/nixpkgs/4af7baf4e70826922cf4010a081f64986d6a5d05").outPath {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  home.packages = [ vscodePkgs.vscode ];

  home.file = {
    "${configDir}/settings.json".source = ../../../../dotfiles/vscode/settings.json;
    "${configDir}/keybindings.json".source = ../../../../dotfiles/vscode/keybindings.json;
  };
}
