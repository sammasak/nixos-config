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

      # nh wraps nixos-rebuild with a readable TUI and a build diff; nvd is the
      # diff engine it shells out to (and is useful standalone).
      nh
      nvd
      nix-prefetch-scripts

      appimage-run
      gawk  # scripts/bench.sh needs asort and a state machine
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
