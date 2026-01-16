# Base system packages
{ pkgs, ... }:
{
  programs = {
    fuse.userAllowOther = true;
    mtr.enable = true;
  };

  environment.systemPackages = with pkgs; [
    # Core utilities
    vim
    wget
    curl
    htop
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

    # Nix tools
    nix-prefetch-scripts
    appimage-run

    # Desktop utilities
    xdg-utils
    wl-clipboard
    grim
    slurp
    brightnessctl
    pavucontrol
    playerctl
    hyprpicker
    grimblast
    swappy
    wf-recorder
    cliphist
    libnotify
    yad
    gawk
    swww
  ];
}
