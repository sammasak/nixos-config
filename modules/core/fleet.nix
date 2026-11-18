# LAN facts that more than one module reads (#291), stated once. Read-only: a host that sets any of it fails as a
# second definition. A fact with a single reader stays in that reader (host keys, cache keys, naked-pi's addresses).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ipv4 = types.strMatching "[0-9]{1,3}([.][0-9]{1,3}){3}";
  endpoint =
    fleet: what:
    mkOption {
      description = "The ${what}: the host it runs on and its port, with the base URL derived from them.";
      type = types.submodule (
        { config, ... }:
        {
          options = {
            host = mkOption {
              type = types.enum (lib.attrNames fleet.hosts);
              description = "networking.hostName of the host serving it; its address comes from hosts.";
            };
            port = mkOption {
              type = types.port;
              description = "The TCP port it listens on, at least on that host's LAN address.";
            };
            url = mkOption {
              type = types.str;
              readOnly = true;
              description = "http://<host's address>:<port>, without a trailing slash; derived, not set.";
              default = "http://${fleet.hosts.${config.host}.address}:${toString config.port}";
            };
          };
        }
      );
    };
in
{
  options.sam.fleet = mkOption {
    readOnly = true;
    description = "Fleet-wide LAN facts, set in modules/core/fleet.nix only.";
    type = types.submodule (fleet: {
      options = {
        hosts = mkOption {
          description = "The fleet's hosts, keyed by networking.hostName (not the flake attribute).";
          type = types.attrsOf (
            types.submodule {
              options = {
                address = mkOption {
                  type = ipv4;
                  description = "The host's LAN IPv4 address, the one other hosts reach it on.";
                };
                extraAddresses = mkOption {
                  type = types.listOf ipv4;
                  description = "Other LAN addresses the host can send from (another NIC), for a source-scoped rule.";
                  default = [ ];
                };
                sleeps = mkOption {
                  type = types.bool;
                  description = "The host may be powered off at any time: the store caches skip it, the alerts expect it (rules/homelab.yaml).";
                  default = false;
                };
                power = mkOption {
                  default = null;
                  description = "A work-hours power window (modules/core/power-schedule.nix); null for an always-on host.";
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        mac = mkOption {
                          type = types.strMatching "[0-9a-f]{2}(:[0-9a-f]{2}){5}";
                          description = "The MAC the waker sends the Wake-on-LAN packet to.";
                        };
                        interface = mkOption {
                          type = types.str;
                          description = "The NIC whose Wake-on-LAN unit the host needs (wol-<interface>).";
                        };
                        wake = mkOption {
                          type = types.str;
                          description = "When the waker sends the packet, as a systemd OnCalendar expression.";
                        };
                        off = mkOption {
                          type = types.str;
                          description = "When the host powers itself off, as a systemd OnCalendar expression.";
                        };
                      };
                    }
                  );
                };
                gpu = mkOption {
                  type = types.nullOr (types.enum [ "nvidia" ]);
                  description = "The host's GPU, for its telemetry (monitoring/gpu-exporter.nix) and black-pi's nvidia-gpu scrape job.";
                  default = null;
                };
              };
            }
          );
        };
        gateway = mkOption {
          type = ipv4;
          description = "The LAN's default gateway, which the Wi-Fi watchdogs ping to judge the link.";
        };
        lanCidr = mkOption {
          type = types.str;
          description = "The trusted LAN as a CIDR: the firewall's and store caches' source scope, and Tailscale's advertised route.";
        };
        deployer = mkOption {
          type = types.str;
          description = "networking.hostName of the host whose user key deploys every host.";
        };
        edge = mkOption {
          type = types.str;
          description = "networking.hostName of the host that serves *.sammasak.dev (edge.nix): the DNS rewrite and the OTLP relay.";
        };
        # by LAN address: a page must not need acer's Caddy
        ntfy = endpoint fleet.config "ntfy server every host pages";
        loki = endpoint fleet.config "Loki every host ships its logs to";
        edgeMetrics = endpoint fleet.config "Caddy's /metrics on the edge host, for black-pi's Prometheus alone";
        pageUrl = mkOption {
          type = types.str;
          readOnly = true;
          description = "The ntfy topic URL a failed service pages; derived from ntfy, not set.";
          default = "${fleet.config.ntfy.url}/homelab-alerts";
        };
      };
    });
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
    ntfy = {
      host = "lenovo-21CB001PMX";
      port = 2586;
    };
    loki = {
      host = "black-pi";
      port = 3100;
    };
    edgeMetrics = {
      host = "acer-swift";
      port = 9180;
    };
  };
}
