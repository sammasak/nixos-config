# Visual Studio Code
# Config managed via dotfiles with symlinks
# Works on both Linux and macOS

{ pkgs, ... }:
let
  configDir = if pkgs.stdenv.isDarwin
    then "Library/Application Support/Code/User"
    else ".config/Code/User";
in
{
  # Just install VSCode, don't manage config
  home.packages = [ pkgs.vscode ];

  # Symlink dotfiles (editable, committable)
  home.file = {
    "${configDir}/settings.json".source = ../../dotfiles/vscode/settings.json;
    "${configDir}/keybindings.json".source = ../../dotfiles/vscode/keybindings.json;
  };
}
