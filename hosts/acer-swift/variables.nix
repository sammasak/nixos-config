{
  # System
  username = "lukas";
  hostname = "acer-swift";
  timezone = "Europe/Stockholm";
  locale = "en_US.UTF-8";
  kbdLayout = "se";
  kbdVariant = "";
  consoleKeymap = "sv-latin1";

  # Hardware
  videoDriver = "intel";

  # Monitor configuration
  monitors = [
    "DP-1,3840x2160@60,1920x0,1.5"
    "eDP-1,preferred,0x0,1"
  ];

  # Features
  laptop = true;
  # herdr host: Pi run viewer panes run pi-view here (devenv-platform#28).
  pi = true;

  # Roles
  roles = [ "base" "laptop" "homelab-agent" ];
}
