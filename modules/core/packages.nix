# Base system packages
{ config, pkgs, lib, ... }:
let
  hasDesktop = config.sam.desktop.enable;
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
    # nodejs + chromium look desktop-only but are load-bearing on headless
    # hosts: the Playwright MCP server (claude-code/mcp.nix) runs
    # `npx @playwright/mcp --executable-path /run/current-system/sw/bin/chromium`
    # for agent browser automation. Do not gate behind hasDesktop.
    nodejs
    chromium
    just

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
    ++ lib.optionals hasDesktop [
      wl-clipboard
      grim
      slurp
      hyprpicker
      grimblast
      swappy
      wf-recorder
      cliphist
      awww
    ];
}
