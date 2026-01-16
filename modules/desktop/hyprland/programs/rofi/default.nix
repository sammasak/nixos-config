# Rofi - Application Launcher
{ pkgs, ... }:
{
  programs.rofi = {
    enable = true;
    package = pkgs.rofi;

    plugins = with pkgs; [
      rofi-emoji
    ];

    extraConfig = {
      modi = "drun,run,filebrowser,window,emoji";
      show-icons = true;
      terminal = "kitty";
      drun-display-format = "{name}";
      disable-history = false;
      hide-scrollbar = true;
      display-drun = " Apps";
      display-run = " Run";
      display-window = " Window";
      display-filebrowser = " Files";
      display-emoji = "󰞅 Emoji";
      sidebar-mode = true;
      case-sensitive = false;
      cycle = true;
      filter = "";
      scroll-method = 0;
      normalize-match = true;
      icon-theme = "Papirus-Dark";
      steal-focus = true;
      matching = "fuzzy";
      tokenize = true;
      cache-dir = "~/.cache/rofi";
      max-history-size = 25;
      window-format = "{w} · {c} · {t}";
    };
  };

  home.packages = with pkgs; [
    rofimoji
  ];
}
