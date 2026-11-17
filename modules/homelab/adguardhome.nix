# AdGuard Home DNS server with DNS-over-TLS (DoT)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.dns;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    optionals
    ;
  # Android Private DNS only speaks DoT on 853.
  dotPort = 853;
  dnsDomain = cfg.tls.domain;
  inherit (import ../../lib/firewall.nix lib) anySourceTcp;
  fw = config.networking.firewall;
  # AdGuard's UI and control API have no users, so loopback keeps them off the LAN. port_https would serve them, and
  # DoH, on this address's IP too (internal/home/web.go), so it is 0: no DoH; DNS and DoT bind dns.bind_hosts
  webPort = 3003;
  webAddress = "127.0.0.1:${toString webPort}";
  textfile = "/run/node-exporter-textfile/adguard.prom";
  writer = "${pkgs.python3}/bin/python3 -I ${../../scripts/adguard-textfile.py}";
  # every fleet name answers its LAN address, and none is served as loopback (NixOS maps this host's own name to
  # 127.0.0.2 in /etc/hosts, which AdGuard would otherwise answer the whole LAN from)
  fleet = config.sam.fleet.hosts;
  loopback = a: lib.hasPrefix "127." a || a == "::1";
  served = config.services.adguardhome.settings;
  hostsLoopback = lib.filter (
    n:
    lib.any (a: loopback a && lib.elem n config.networking.hosts.${a}) (
      lib.attrNames config.networking.hosts
    )
  ) (lib.attrNames fleet);
  rewritesLoopback = map (r: r.domain) (
    lib.filter (r: fleet ? ${r.domain} && loopback r.answer) served.filtering.rewrites
  );
in
{
  imports = [ ./acme.nix ];

  options.homelab.dns = {
    enable = mkEnableOption "AdGuard Home DNS server";

    tls.enable = mkEnableOption "DNS-over-TLS (DoT)";

    tls.domain = mkOption {
      type = types.str;
      default = "dns.sammasak.dev";
      description = "DNS service domain for the DoT certificate";
    };

    rewrites = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            domain = mkOption {
              type = types.str;
              description = "Domain pattern (supports wildcards like *.example.com)";
            };
            answer = mkOption {
              type = types.str;
              description = "IP address or CNAME to return";
            };
          };
        }
      );
      default = [ ];
      description = "DNS rewrites for internal domain resolution";
      example = [
        {
          domain = "*.sammasak.dev";
          answer = "192.168.10.200";
        }
        {
          domain = "dns.sammasak.dev";
          answer = "192.168.10.154";
        }
      ];
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.prometheus.exporters.node.enable;
        message = "modules/homelab/adguardhome.nix: adguard-textfile writes a textfile metric; import monitoring/node-exporter.nix.";
      }
      {
        assertion = cfg.tls.enable -> config.homelab.acme.enable;
        message = "homelab.dns.tls serves the ACME certificate for homelab.dns.tls.domain, which needs homelab.acme.enable.";
      }
      {
        assertion =
          lib.hasPrefix "127.0.0.1:" config.services.adguardhome.settings.http.address
          && (config.services.adguardhome.settings.tls.port_https or 0) == 0
          && !config.services.adguardhome.openFirewall
          && anySourceTcp fw [ webPort ] == [ ];
        message = "modules/homelab/adguardhome.nix: AdGuard's control API has no users, so http.address stays on 127.0.0.1 (it is ${config.services.adguardhome.settings.http.address}), tls.port_https stays 0 and port ${toString webPort} stays closed.";
      }
      {
        assertion = (served.dns.hostsfile_enabled or true) == false || hostsLoopback == [ ];
        message = "modules/homelab/adguardhome.nix: AdGuard answers the LAN from this host's /etc/hosts, which maps ${toString hostsLoopback} to loopback (nixos-config#503): keep dns.hostsfile_enabled false.";
      }
      {
        assertion = rewritesLoopback == [ ];
        message = "modules/homelab/adguardhome.nix: a DNS rewrite serves the fleet host ${toString rewritesLoopback} as loopback; every fleet name answers its sam.fleet address.";
      }
    ];

    # upstream's own validator on the rendered file: nixpkgs puts it in a checkPhase that pkgs.formats.yaml's
    # runCommand never runs, so without this a value its parser rejects is only found by preStart on lenovo
    system.checks = [
      (pkgs.runCommand "adguardhome-config-check"
        { nativeBuildInputs = [ config.services.adguardhome.package ]; }
        ''
          install -m 0600 ${
            (pkgs.formats.yaml { }).generate "AdGuardHome.yaml" config.services.adguardhome.settings
          } AdGuardHome.yaml
          AdGuardHome -c AdGuardHome.yaml -w "$TMPDIR" --check-config
          touch $out
        ''
      )
      # the declared settings, served: AdGuard runs in the sandbox on loopback (TLS off, no upstream reachable) and must
      # answer each fleet name, single-label and in mixed case as a client may send it, with its fleet address
      (pkgs.runCommand "adguardhome-fleet-names"
        {
          nativeBuildInputs = [
            config.services.adguardhome.package
            pkgs.dnsutils
          ];
        }
        ''
          install -m 0600 ${
            (pkgs.formats.yaml { }).generate "AdGuardHome.yaml" (
              lib.recursiveUpdate served {
                http.address = "127.0.0.1:13003";
                dns = {
                  bind_hosts = [ "127.0.0.1" ];
                  port = 15353;
                };
                tls.enabled = false;
              }
            )
          } AdGuardHome.yaml
          AdGuardHome -c AdGuardHome.yaml -w "$TMPDIR" --no-check-update > adguard.log 2>&1 &
          pid=$!
          # dig exits non-zero on no answer; that is a result here, not a build failure
          ask() { dig +time=1 +tries=1 +short -p 15353 @127.0.0.1 "$1" A || true; }
          for _ in $(seq 60); do ask '${lib.head (lib.attrNames fleet)}' | grep -Eq '^[0-9]+[.]' && break; sleep 0.5; done
          bad=0
          ${lib.concatStrings (
            lib.mapAttrsToList (name: h: ''
              for q in ${name} ${lib.toUpper name} ${lib.toLower name}; do
                got=$(ask "$q" | tr '\n' ' '); [ "$got" = "${h.address} " ] || { echo "$q answered '$got', not ${h.address}"; bad=1; }
              done
            '') fleet
          )}
          # a name with no rewrite must not borrow a fleet address: the answers above are the rewrites', not a catch-all
          got=$(ask not-a-fleet-host | tr '\n' ' ')
          case " $got" in *" 192.168."*) echo "not-a-fleet-host answered '$got'"; bad=1 ;; esac
          # the textfile writer against this AdGuard: its control API must give every series the DNS dashboard reads
          ${writer} http://127.0.0.1:13003 dns.prom
          for m in up protection_enabled queries blocked avg_processing_seconds; do
            grep -q "^homelab_dns_$m " dns.prom || { echo "adguard-textfile wrote no homelab_dns_$m"; cat dns.prom; bad=1; }
          done
          grep -qx 'homelab_dns_up 1' dns.prom || { echo "adguard-textfile: AdGuard not up"; bad=1; }
          kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
          [ "$bad" = 0 ] || { echo "--- AdGuard log"; tail -n 20 adguard.log; exit 1; }
          mkdir $out
          cp dns.prom $out/
        ''
      )
    ];

    security.acme.certs.${dnsDomain} = mkIf cfg.tls.enable {
      group = "acme";
      reloadServices = [ "adguardhome.service" ];
    };

    services.adguardhome = {
      enable = true;
      openFirewall = false;
      # keeps runtime state and changes made in the UI (an SSH tunnel to 127.0.0.1:3003); the declared settings are
      # merged in on every start and win
      mutableSettings = true;

      settings = {
        http.address = webAddress;
        dns = {
          bind_hosts = [ "0.0.0.0" ];
          port = 53;
          upstream_dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          bootstrap_dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          # LAN-only resolver: the default 20 queries/s per client drops a build host's parallel lookups
          # (40 at once from acer: 20 fail with "Could not resolve host").
          ratelimit = 0;
          # this host's /etc/hosts maps its own name to 127.0.0.2; answering the LAN from it sent every host's ssh to
          # itself. The fleet's names come from the rewrites below instead.
          hostsfile_enabled = false;
        };

        tls = mkIf cfg.tls.enable {
          enabled = true;
          server_name = dnsDomain;
          port_https = 0;
          port_dns_over_tls = dotPort;
          port_dns_over_quic = 0; # Disabled
          certificate_path = "/var/lib/acme/${dnsDomain}/fullchain.pem";
          private_key_path = "/var/lib/acme/${dnsDomain}/key.pem";
          allow_unencrypted_doh = false;
        };

        filtering = {
          filtering_enabled = true;
          protection_enabled = true;
          rewrites =
            map (r: {
              domain = r.domain;
              answer = r.answer;
              enabled = true;
            }) cfg.rewrites
            # each fleet host's name answers its LAN address (modules/core/fleet.nix)
            ++ lib.mapAttrsToList (name: h: {
              domain = name;
              answer = h.address;
              enabled = true;
            }) fleet;
        };
      };
    };

    networking.firewall = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = optionals cfg.tls.enable [ dotPort ];
    };

    # AdGuard's counters for black-pi, through node-exporter's textfile directory: the control API stays on loopback,
    # and no port opens. The unit may reach loopback alone.
    systemd.services.adguard-textfile = {
      after = [ "adguardhome.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${writer} http://${webAddress} ${textfile}";
        DynamicUser = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ (builtins.dirOf textfile) ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };
    systemd.timers.adguard-textfile = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "minutely";
    };

    # Without the ACME group AdGuard cannot read its own certificate.
    systemd.services.adguardhome = mkIf cfg.tls.enable {
      after = [ "acme-${dnsDomain}.service" ];
      wants = [ "acme-${dnsDomain}.service" ];
      serviceConfig.SupplementaryGroups = [ "acme" ];
    };
  };
}
