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

  # Features
  # herdr host: Pi run viewer panes run pi-view here (devenv-platform#28).
  pi = true;

  # Roles
  roles = [ "base" "laptop" "homelab-agent" ];
}
