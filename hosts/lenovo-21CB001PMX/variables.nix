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

  # Features
  laptop = true;
  games = false;

  # Roles
  roles = [ "base" "laptop" "desktop" ];
}
