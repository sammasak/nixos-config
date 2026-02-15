# i3 desktop (Home Manager)
{ pkgs, lib, osConfig ? null, ... }:
let
  profile =
    if osConfig != null && osConfig ? sam && osConfig.sam ? profile
    then osConfig.sam.profile
    else {
      terminal = "kitty";
      browser = "firefox";
      defaultWallpaper = "train-sideview.webp";
    };

  wallpapersDir = ../../../assets/wallpapers;
  defaultWallpaper = wallpapersDir + "/${profile.defaultWallpaper}";

  wallpaper-init = pkgs.writeShellScriptBin "wallpaper-init" ''
    #!/usr/bin/env bash
    set -euo pipefail
    ${pkgs.feh}/bin/feh --no-fehbg --bg-fill "${defaultWallpaper}"
  '';
in
{
  imports = [
    # Reuse the shared GTK look from the Hyprland stack (not Hyprland-specific).
    ../hyprland/programs/gtk/default.nix
  ];

  home.packages = with pkgs; [
    feh
    flameshot
    xclip
    wallpaper-init
  ];

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;

    plugins = with pkgs; [
      rofi-emoji
    ];

    extraConfig = {
      modi = "drun,run,filebrowser,window,emoji";
      show-icons = true;
      terminal = profile.terminal;
      drun-display-format = "{name}";
      disable-history = false;
      hide-scrollbar = true;
      display-drun = " Apps";
      display-run = " Run";
      display-window = " Window";
      display-filebrowser = " Files";
      display-emoji = " Emoji";
      sidebar-mode = true;
      case-sensitive = false;
      cycle = true;
      matching = "fuzzy";
      tokenize = true;
      cache-dir = "~/.cache/rofi";
      max-history-size = 25;
      window-format = "{w} · {c} · {t}";
    };
  };

  services.dunst.enable = true;

  # Minimal i3 config that mirrors the Hyprland keybind muscle memory.
  xdg.configFile."i3/config".text = ''
    set $mod Mod4

    set $term ${profile.terminal}
    set $browser ${profile.browser}
    set $files thunar

    font pango:monospace 10

    # Avoid inheriting SDDM's root background pixmap.
    exec --no-startup-id xsetroot -solid "#111111"
    exec --no-startup-id wallpaper-init

    # Launchers
    bindsym $mod+Return exec $term
    bindsym $mod+Shift+Return exec $term
    bindsym $mod+d exec rofi -show drun
    bindsym $mod+space exec rofi -show drun
    bindsym $mod+e exec $files
    bindsym $mod+b exec $browser

    # Window management
    bindsym $mod+q kill
    bindsym $mod+Shift+q exec "i3-msg exit"
    bindsym $mod+f fullscreen toggle
    bindsym $mod+w floating toggle
    bindsym $mod+c floating enable; move position center
    bindsym $mod+y sticky toggle

    # Focus (vim-style)
    bindsym $mod+h focus left
    bindsym $mod+j focus down
    bindsym $mod+k focus up
    bindsym $mod+l focus right

    # Move (vim-style)
    bindsym $mod+Shift+h move left
    bindsym $mod+Shift+j move down
    bindsym $mod+Shift+k move up
    bindsym $mod+Shift+l move right

    # Resize (match Hyprland: SUPER+CTRL+H/J/K/L)
    bindsym $mod+Control+h resize shrink width 50 px or 5 ppt
    bindsym $mod+Control+l resize grow width 50 px or 5 ppt
    bindsym $mod+Control+k resize shrink height 50 px or 5 ppt
    bindsym $mod+Control+j resize grow height 50 px or 5 ppt

    # Workspaces
    bindsym $mod+1 workspace number 1
    bindsym $mod+2 workspace number 2
    bindsym $mod+3 workspace number 3
    bindsym $mod+4 workspace number 4
    bindsym $mod+5 workspace number 5
    bindsym $mod+6 workspace number 6
    bindsym $mod+7 workspace number 7
    bindsym $mod+8 workspace number 8
    bindsym $mod+9 workspace number 9
    bindsym $mod+0 workspace number 10

    bindsym $mod+Shift+1 move container to workspace number 1
    bindsym $mod+Shift+2 move container to workspace number 2
    bindsym $mod+Shift+3 move container to workspace number 3
    bindsym $mod+Shift+4 move container to workspace number 4
    bindsym $mod+Shift+5 move container to workspace number 5
    bindsym $mod+Shift+6 move container to workspace number 6
    bindsym $mod+Shift+7 move container to workspace number 7
    bindsym $mod+Shift+8 move container to workspace number 8
    bindsym $mod+Shift+9 move container to workspace number 9
    bindsym $mod+Shift+0 move container to workspace number 10

    # Scratchpad == Hyprland "minimized"
    bindsym $mod+n move scratchpad
    bindsym $mod+Shift+n scratchpad show

    # App switcher
    bindsym $mod+Tab exec rofi -show window

    # Screenshot
    bindsym Print exec flameshot gui

    # Lock
    bindsym $mod+Escape exec i3lock -c 000000

    # i3bar
    bar {
      status_command i3status
    }
  '';
}

