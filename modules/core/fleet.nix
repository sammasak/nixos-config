# LAN facts that more than one module reads (#291), stated once. Read-only: a host that sets any of it fails as a
# second definition. A fact with a single reader stays in that reader (host keys, cache keys, naked-pi's addresses).
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
          type = types.attrsOf (
            types.submodule {
              options = {
                address = mkOption { type = ipv4; };
                # a second LAN address the host can send from (another NIC), for a source-scoped rule
                extraAddresses = mkOption {
                  type = types.listOf ipv4;
                  default = [ ];
                };
                # may be powered off at any time: the store caches skip it, the alerts expect it (rules/homelab.yaml)
                sleeps = mkOption {
                  type = types.bool;
                  default = false;
                };
                # a work-hours window (modules/core/power-schedule.nix): the waker sends a Wake-on-LAN packet to mac
                # at wake, the host powers off at off (systemd OnCalendar); interface is the NIC whose wol unit it needs
                power = mkOption {
                  default = null;
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        mac = mkOption { type = types.strMatching "[0-9a-f]{2}(:[0-9a-f]{2}){5}"; };
                        interface = mkOption { type = types.str; };
                        wake = mkOption { type = types.str; };
                        off = mkOption { type = types.str; };
                      };
                    }
                  );
                };
              };
            }
          );
        };
        gateway = mkOption { type = ipv4; };
        lanCidr = mkOption { type = types.str; };
        # networking.hostName of the host whose user key deploys every host
        deployer = mkOption { type = types.str; };
        # networking.hostName of the host that serves *.sammasak.dev (edge.nix): the DNS rewrite and the OTLP relay
        edge = mkOption { type = types.str; };
      };
    };
  };

  config.sam.fleet = {
    hosts = {
      lenovo-21CB001PMX.address = "192.168.10.154";
      acer-swift.address = "192.168.10.110";
      # dual-boot towers, often off or in Windows; both power off nights and weekends (power-schedule.nix)
      msi-ms7758 = {
        address = "192.168.10.235";
        sleeps = true;
        power = {
          mac = "d4:3d:7e:4a:f9:3d";
          interface = "enp3s0";
          wake = "Mon-Fri 08:30";
          off = "Mon-Fri 21:00";
        };
      };
      asus-b460m = {
        address = "192.168.10.113";
        sleeps = true;
        power = {
          mac = "f0:2f:74:32:6b:7f";
          interface = "eno1";
          wake = "Mon-Fri 08:30";
          off = "Mon-Fri 21:00";
        };
      };
      # address is end0, extraAddresses wlan0
      black-pi = {
        address = "192.168.10.137";
        extraAddresses = [ "192.168.10.136" ];
      };
    };
    gateway = "192.168.10.1";
    lanCidr = "192.168.10.0/24";
    deployer = "lenovo-21CB001PMX";
    edge = "acer-swift";
  };
}
