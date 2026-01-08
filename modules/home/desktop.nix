{pkgs, ... }:
{
  home.packages = with pkgs; [
    firefox
    vscode
  ];

  xdg.configFile."Code/User/settings.json".source = ../../dotfiles/vscode/settings.json;
}
