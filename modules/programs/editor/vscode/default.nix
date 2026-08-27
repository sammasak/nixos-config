{ pkgs, config, ... }:
let
  configDir = if pkgs.stdenv.isDarwin
    then "Library/Application Support/Code/User"
    else ".config/Code/User";
  repoRoot = "/home/lukas/nixos-config";
in
{
  home.packages = [ pkgs.vscode ];

  home.file = {
    "${configDir}/settings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/settings.json";
    "${configDir}/keybindings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/keybindings.json";
  };
}
