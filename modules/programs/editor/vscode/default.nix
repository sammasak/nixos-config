# Visual Studio Code
{ pkgs, config, ... }:
let
  configDir = if pkgs.stdenv.isDarwin
    then "Library/Application Support/Code/User"
    else ".config/Code/User";
  vscodePkgs = import (builtins.getFlake "github:NixOS/nixpkgs/4af7baf4e70826922cf4010a081f64986d6a5d05").outPath {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
  repoRoot = "/home/lukas/nixos-config";
in
{
  home.packages = [ vscodePkgs.vscode ];

  home.file = {
    "${configDir}/settings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/settings.json";
    "${configDir}/keybindings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/keybindings.json";
  };
}
