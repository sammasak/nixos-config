# LAN facts that more than one module reads (#291), stated once. Read-only: a host that sets any of it fails as a
# second definition. A fact with a single reader stays in that reader (host keys, cache keys, the Pis' addresses).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ipv4 = types.strMatching "[0-9]{1,3}([.][0-9]{1,3}){3}";
in
{
  options.sam.fleet = mkOption {
    readOnly = true;
    description = "Fleet-wide LAN facts, set in modules/core/fleet.nix only.";
    type = types.submodule {
      options = {
        # keyed by networking.hostName
        hosts = mkOption {
          type = types.attrsOf (types.submodule { options.address = mkOption { type = ipv4; }; });
        };
        gateway = mkOption { type = ipv4; };
      };
    };
  };

  config.sam.fleet = {
    hosts = {
      lenovo-21CB001PMX.address = "192.168.10.154";
      acer-swift.address = "192.168.10.110";
      msi-ms7758.address = "192.168.10.235";
    };
    gateway = "192.168.10.1";
  };
}
