# Visual Studio Code
{ pkgs, ... }:
let
  configDir = if pkgs.stdenv.isDarwin
    then "Library/Application Support/Code/User"
    else ".config/Code/User";
in
{
  home.packages = [ pkgs.vscode ];

  home.file = {
    "${configDir}/settings.json".source = ../../../../dotfiles/vscode/settings.json;
    "${configDir}/keybindings.json".source = ../../../../dotfiles/vscode/keybindings.json;
  };
}
