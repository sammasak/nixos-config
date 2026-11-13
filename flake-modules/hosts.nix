# The hosts table: one entry per nixosConfigurations output (30-configurations-options.nix).
{
  configurations.nixos = {
    lenovo = { hostDir = "lenovo-21CB001PMX"; roles = [ "base" "laptop" "homelab-server" ]; };
    acer-swift.roles = [ "base" "laptop" "homelab-agent" "runtime-host" ];
    msi-ms7758.roles = [ "base" "homelab-agent" "runtime-host" ];
    black-pi.roles = [ "base" "homelab-agent" ];
    naked-pi.roles = [ "base" "rf-lab" "embedded" ];
  };
}
