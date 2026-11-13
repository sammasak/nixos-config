{
  # System
  username = "lukas";
  hostname = "acer-swift";

  # Features
  # herdr host: Pi run viewer panes run pi-view here (devenv-platform#28).
  pi = true;

  # Roles
  roles = [ "base" "laptop" "homelab-agent" "runtime-host" ];
  nativeOtel = true;
}
