# Host-specific variables for lenovo-21CB001PMX
{
  # System
  username = "lukas";
  hostname = "lenovo-21CB001PMX";
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
    "eDP-1,preferred,2186x1440,1"
  ];

  # Features
  laptop = true;
  games = false;

  # Roles
  roles = [ "base" "laptop" "desktop" ];
}
