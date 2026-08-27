{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ripgrep
    fastfetch
    fd
    jq
    tree
  ];
}
