# Base system packages
{ config, pkgs, lib, ... }:
let
  roles = config.sam.profile.roles or [ ];
  hasDesktop = builtins.elem "desktop" roles;
  isHyprland = config.sam.profile.desktop == "hyprland";
in
{
  programs = {
    fuse.userAllowOther = true;
    mtr.enable = true;
  };

  environment.systemPackages =
    with pkgs;
    [
    # Core utilities
    vim
    wget
    curl
    htop
    tmux
    killall
    lm_sensors

    # File handling
    unrar
    unzip
    jq

    # Development
    git
    gh
    fzf
    fd
    ripgrep
    tldr
    claude-code

    # Nix tools
    nix-prefetch-scripts
    appimage-run
    gawk
    ]
    ++ lib.optionals hasDesktop [
      # Desktop utilities
      xdg-utils
      gnome-disk-utility
      brightnessctl
      pavucontrol
      playerctl
      libnotify
      yad
    ]
    ++ lib.optionals (hasDesktop && isHyprland) [
      wl-clipboard
      grim
      slurp
      hyprpicker
      grimblast
      swappy
      wf-recorder
      cliphist
      swww
    ];
}
