{config, pkgs, ...}:
{
  imports = [
    ../../modules/home/base.nix
    ../../modules/home/desktop/hyprland
    ../../modules/home/desktop.nix
  ];

  home.username = "lukas";
  home.homeDirectory = "/home/lukas";
  home.stateVersion = "25.11";
}
