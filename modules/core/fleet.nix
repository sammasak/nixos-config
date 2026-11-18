# LAN facts that more than one module reads (#291), stated once. Read-only: a host that sets any of it fails as a
# second definition. A fact with a single reader stays in that reader (host keys, cache keys, naked-pi's addresses).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ipv4 = types.strMatching "[0-9]{1,3}([.][0-9]{1,3}){3}";
  hostName = fleet: types.enum (lib.attrNames fleet.hosts);
  endpointType =
    fleet:
    types.submodule (
      { config, ... }:
      {
        options = {
          host = mkOption {
            type = hostName fleet;
            description = "networking.hostName of the host serving it; its address comes from hosts.";
          };
          port = mkOption {
            type = types.port;
            description = "The port it listens on, at least on that host's LAN address.";
          };
          proto = mkOption {
            type = types.enum [
              "tcp"
              "udp"
            ];
            default = "tcp";
            description = "The port's protocol.";
          };
          from = mkOption {
            type = types.listOf (hostName fleet);
            default = [ ];
            description = "The hosts that call it: modules/core/network.nix admits each one's address and extraAddresses, nothing else.";
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
  endpoint =
    fleet: what:
    mkOption {
      description = "The ${what}: the host it runs on and its port, with the base URL derived from them.";
      type = endpointType fleet;
    };
  # every other host ships its journal there (journal-collector.nix)
  loki = {
    host = "black-pi";
    port = 3100;
    from = lib.remove loki.host (lib.attrNames hosts);
  };
  # the fleet's one night: the windowed hosts are off through it on weekdays (and all weekend), the quiet hosts run
  # throttled through it every night (power-schedule.nix)
  night = {
    start = "21:00";
    end = "08:30";
  };
  hosts = {
    # fans that stay on: throttled at night; 60 % is the measured start (acer 90->71 C, lenovo 74->59 C under a gate)
    lenovo-21CB001PMX = {
      address = "192.168.10.154";
      quiet = {
        driver = "intel_pstate";
        maxPerfPct = 60;
      };
    };
    acer-swift = {
      address = "192.168.10.110";
      quiet = {
        driver = "intel_pstate";
        maxPerfPct = 60;
      };
    };
    # dual-boot towers, often off or in Windows; both power off nights and weekends (power-schedule.nix)
    msi-ms7758 = {
      address = "192.168.10.235";
      sleeps = true;
      power = {
        mac = "d4:3d:7e:4a:f9:3d";
        interface = "enp3s0";
        wake = "Mon-Fri ${night.end}";
        off = "Mon-Fri ${night.start}";
      };
    };
    asus-b460m = {
      address = "192.168.10.113";
      sleeps = true;
      gpu = "nvidia";
      power = {
        mac = "f0:2f:74:32:6b:7f";
        interface = "eno1";
        wake = "Mon-Fri ${night.end}";
        off = "Mon-Fri ${night.start}";
        manualOff = true;
      };
    };
    # address is end0, extraAddresses wlan0
    black-pi = {
      address = "192.168.10.137";
      extraAddresses = [ "192.168.10.136" ];
    };
  };
  edge = "acer-swift";
  edgeMetrics = {
    host = edge;
    port = 9180;
    from = [ "black-pi" ];
  };
  # black-pi's Prometheus scrapes every host's node-exporter, and nvidia-gpu where sam.fleet says gpu
  scraped =
    name: port: only:
    lib.mapAttrs' (
      h: _:
      lib.nameValuePair "${name}-${h}" {
        host = h;
        inherit port;
        from = [ "black-pi" ];
      }
    ) (lib.filterAttrs (_: only) hosts);
  # the hosts with sam.storeCache (lenovo, the runtime-host role; store-cache.nix asserts both ways): every other fleet
  # host substitutes from it, worker guests through their host's NAT
  storeCaches = [
    "lenovo-21CB001PMX"
    "acer-swift"
    "msi-ms7758"
    "asus-b460m"
  ];
  ntfy = {
    host = "lenovo-21CB001PMX";
    port = 2586;
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
                  description = "The host may be powered off at any time: the store caches skip it, the alerts expect it (modules/homelab/monitoring/rules/homelab.yaml).";
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
                        manualOff = mkOption {
                          type = types.bool;
                          description = "The owner also powers the host off by hand, so the alerts expect it off at any time, not only outside this window (modules/homelab/monitoring/rules/homelab.nix).";
                          default = false;
                        };
                      };
                    }
                  );
                };
                quiet = mkOption {
                  default = null;
                  description = "Throttled every night instead of powered off, for a host whose fans stay on (modules/core/power-schedule.nix); null for none. Not with a power window.";
                  type = types.nullOr (
                    types.submodule {
                      options = {
                        driver = mkOption {
                          type = types.enum [ "intel_pstate" ];
                          description = "The CPU frequency driver the throttle writes to (/sys/devices/system/cpu/intel_pstate): stated, not assumed; the host asserts it can have it.";
                        };
                        maxPerfPct = mkOption {
                          type = types.ints.between 10 100;
                          description = "intel_pstate's max_perf_pct through the night, with turbo off; 100 and turbo on by day.";
                        };
                      };
                    }
                  );
                };
                gpu = mkOption {
                  type = types.nullOr (types.enum [ "nvidia" ]);
                  description = "The host's GPU, for its telemetry (modules/homelab/monitoring/gpu-exporter.nix) and black-pi's nvidia-gpu scrape job.";
                  default = null;
                };
              };
            }
          );
        };
        night = mkOption {
          description = "The fleet's night, as times of day: power windows switch off at its start and wake at its end on their days, quiet hosts throttle through it every night.";
          type = types.submodule {
            options = {
              start = mkOption {
                type = types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
                description = "HH:MM the night starts.";
              };
              end = mkOption {
                type = types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
                description = "HH:MM the night ends.";
              };
            };
          };
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
        listeners = mkOption {
          description = "Every port one fleet host serves another: modules/core/network.nix renders each one's firewall rule from `from`, and fails a host whose firewall admits anything not here or in public. Its serving module takes its port from here (config.sam.fleet.listeners.<name>.port).";
          type = types.attrsOf (endpointType fleet.config);
        };
        public = mkOption {
          description = "What may be open beyond the listeners, each with its reason: a port to any source or (lan) to lanCidr, or a trusted interface (port null).";
          type = types.listOf (
            types.submodule {
              options = {
                host = mkOption {
                  type = types.nullOr (hostName fleet.config);
                  default = null;
                  description = "networking.hostName it may be open on; null: every host, naked-pi too.";
                };
                port = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "The port; null: every port of `interface`, a trusted interface.";
                };
                proto = mkOption {
                  type = types.enum [
                    "tcp"
                    "udp"
                  ];
                  default = "tcp";
                  description = "The port's protocol.";
                };
                interface = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Open on this interface only; null: every interface.";
                };
                lan = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Admitted from lanCidr by a source rule its module renders, not open to any source.";
                };
                why = mkOption {
                  type = types.str;
                  description = "Why it is open.";
                };
              };
            }
          );
        };
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
    inherit
      hosts
      night
      edge
      loki
      edgeMetrics
      ;
    gateway = "192.168.10.1";
    lanCidr = "192.168.10.0/24";
    deployer = "lenovo-21CB001PMX";
    inherit ntfy;
    listeners = {
      inherit loki;
      edge-metrics = edgeMetrics;
      alertmanager = {
        host = "black-pi";
        port = 9093;
        # the cluster-watchdog reads /-/ready and the Watchdog alert; Prometheus there arrives on loopback
        from = [ "lenovo-21CB001PMX" ];
      };
      alert-bridge = {
        host = "lenovo-21CB001PMX";
        port = 9099;
        # Alertmanager has no outgoing-source setting: with end0 down it sends from wlan0 (extraAddresses)
        from = [ "black-pi" ];
      };
      prometheus = {
        host = "black-pi";
        port = 9090;
        # acer's alloy-otlp pushes OTLP, lenovo's watchdog and harness usage report read; Grafana there is loopback
        from = [
          "acer-swift"
          "lenovo-21CB001PMX"
        ];
      };
      grafana = {
        host = "black-pi";
        port = 3000;
        # Caddy on the edge (edge.nix)
        from = [ edge ];
      };
      gateway-api = {
        host = "acer-swift";
        port = 8081;
        from = [ "lenovo-21CB001PMX" ];
      };
      gateway-admin = {
        host = "acer-swift";
        port = 9091;
        from = [ "black-pi" ];
      };
      alloy-http = {
        host = "acer-swift";
        port = 12346;
        from = [ "black-pi" ];
      };
      # Pi on lenovo and acer, and acer's gateway, call it directly
      ollama-msi = {
        host = "msi-ms7758";
        port = 11434;
        from = [
          "lenovo-21CB001PMX"
          "acer-swift"
        ];
      };
      ollama-asus = {
        host = "asus-b460m";
        port = 11434;
        from = [ "acer-swift" ];
      };
    }
    // scraped "node-exporter" 9100 (_: true)
    // scraped "nvidia-gpu" 9835 (h: h.gpu or null != null)
    // lib.listToAttrs (
      map (
        h:
        lib.nameValuePair "store-cache-${h}" {
          host = h;
          port = 5000;
          from = lib.remove h (lib.attrNames hosts);
        }
      ) storeCaches
    );
    public = [
      {
        port = 22;
        lan = true;
        why = "SSH, key-only: management and break-glass from the LAN (network.nix).";
      }
      {
        port = 67;
        proto = "udp";
        interface = "wlan0";
        why = "DHCP for the rf-lab AP's own clients, on its radio only (rf-lab/ap.nix; off while nothing enables it).";
      }
      {
        host = "lenovo-21CB001PMX";
        port = 53;
        proto = "udp";
        why = "AdGuard, the LAN's resolver.";
      }
      {
        host = "lenovo-21CB001PMX";
        port = 853;
        why = "AdGuard DNS-over-TLS, Android Private DNS.";
      }
      {
        inherit (ntfy) host port;
        why = "ntfy for the phone on home Wi-Fi; unauthenticated, scoping it is the owner's call.";
      }
      {
        host = "lenovo-21CB001PMX";
        port = 41641;
        proto = "udp";
        why = "tailscaled's direct path.";
      }
      {
        host = "lenovo-21CB001PMX";
        interface = "tailscale0";
        why = "the phone's tailnet path: every port, to every tailnet peer (tailscale.nix).";
      }
      {
        host = edge;
        port = 80;
        why = "Caddy, the edge: ACME and the redirect to 443.";
      }
      {
        host = edge;
        port = 443;
        why = "Caddy, the edge: every *.sammasak.dev site, each with its own auth.";
      }
      {
        host = edge;
        port = 443;
        proto = "udp";
        why = "Caddy, the edge: HTTP/3.";
      }
    ];
  };
}
