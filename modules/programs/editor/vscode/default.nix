{ pkgs, config, ... }:
let
  repoRoot = "/home/lukas/nixos-config";
in
{
  home.packages = [ pkgs.vscode ];

  xdg.configFile = {
    "Code/User/settings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/settings.json";
    "Code/User/keybindings.json".source = config.lib.file.mkOutOfStoreSymlink "${repoRoot}/dotfiles/vscode/keybindings.json";
  };
}
