# Common CLI tools
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ripgrep
    neofetch
    fd
    jq
    tree
  ];
}
