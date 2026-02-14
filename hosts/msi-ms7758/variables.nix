# Host-specific variables for msi-ms7758
{
  # System
  username = "lukas";
  hostname = "msi-ms7758";
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
  # Discrete GPU: NVIDIA GeForce GTX 680 (Kepler) -> legacy 470 driver.
  videoDriver = "nvidia-kepler";

  # Monitor configuration (Hyprland): apply defaults to all monitors.
  monitors = [
    # On this host, the firmware framebuffer (simpledrm) shows up as a fake
    # monitor ("Unknown-1"). If we don't disable it, Hyprland will often place
    # the real HDMI monitor to the right and start on the invisible one,
    # resulting in an apparent black screen after login.
    "Unknown-1,disable"
    "HDMI-A-1,preferred,auto,1"
  ];

  # Features
  laptop = false;
  games = true;

  # Roles
  roles = [ "base" "desktop" "homelab-agent" ];
}
