# Base system packages
{ config, pkgs, lib, ... }:
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
    gnome-disk-utility

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

    # Desktop utilities
    xdg-utils
    brightnessctl
    pavucontrol
    playerctl
    libnotify
    yad
    gawk
    ]
    ++ lib.optionals (config.sam.profile.desktop == "hyprland") [
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
