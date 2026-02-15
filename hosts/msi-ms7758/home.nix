# Home Manager configuration for msi-ms7758
{ lib, osConfig, ... }:
let
  profile = osConfig.sam.profile;
  roles = profile.roles;
  hasDesktop = builtins.elem "desktop" roles;
  baseImports = [
    ../../modules/core/nushell.nix
    ../../modules/core/starship.nix
    ../../modules/programs/cli/git
    ../../modules/programs/cli/cli-tools
  ];
  desktopImports = lib.optionals hasDesktop [
    ../../modules/desktop/${profile.desktop}/home.nix
    ../../modules/programs/terminal/${profile.terminal}
    ../../modules/programs/browser/${profile.browser}
    ../../modules/programs/editor/${profile.editor}
  ];
in
{
  home.stateVersion = "25.11";

  imports = baseImports ++ desktopImports;

  # Minimal i3 config so the X11 fallback session is usable even if the user
  # hasn't run i3-config-wizard yet.
  xdg.configFile."i3/config".text = ''
    # i3 fallback config for msi-ms7758 (NVIDIA Kepler / 470xx)
    set $mod Mod4

    # Use a very conservative X11 terminal. (kitty is fine too, but xterm tends
    # to work even on brittle legacy drivers.)
    set $term xterm
    set $browser firefox

    font pango:monospace 10

    # Basics
    bindsym $mod+Return exec $term
    bindsym $mod+Shift+Return exec $term
    bindsym $mod+d exec dmenu_run
    bindsym $mod+b exec $browser
    bindsym $mod+Shift+q kill
    bindsym $mod+Shift+r restart

    # Exit prompt
    bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Exit' 'i3-msg exit'"

    # Focus (vim-style)
    bindsym $mod+h focus left
    bindsym $mod+j focus down
    bindsym $mod+k focus up
    bindsym $mod+l focus right

    # Move
    bindsym $mod+Shift+h move left
    bindsym $mod+Shift+j move down
    bindsym $mod+Shift+k move up
    bindsym $mod+Shift+l move right

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

    # i3bar
    bar {
      status_command i3status
    }
  '';
}
