# Host-specific variables for acer-swift
{
  # System
  username = "lukas";
  hostname = "acer-swift";
  lanCidr = "192.168.10.0/24";
  sshAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDij+mo4z7FsJdwY1GKqrXGqSLIJoq/lNlhW+V1eKMDH lukas@lenovo-21CB001PMX"
  ];
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Desktop
  desktop = "hyprland";
  waybarTheme = "minimal";
  sddmTheme = "astronaut";
  defaultWallpaper = "train-sideview.webp";

  # Applications
  terminal = "kitty";
  browser = "firefox";
  editor = "vscode";
  shell = "nushell";
  tuiFileManager = "yazi";

  # Hardware
  videoDriver = "intel";

  # Monitor configuration
  monitors = [
    "DP-1,3840x2160@60,1920x0,1.5"
    "eDP-1,preferred,0x0,1"
  ];

  # Features
  laptop = true;
  games = false;

  # Roles
  roles = [ "base" "laptop" "desktop" "homelab-agent" ];
}
