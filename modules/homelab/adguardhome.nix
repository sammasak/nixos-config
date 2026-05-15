# AdGuard Home DNS server with encrypted DNS support (DoT/DoH)
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.dns;
  inherit (lib) mkEnableOption mkOption mkIf types optionals;

  # Override adguardhome to v0.107.74 (schema_version 34).
  # The nixpkgs pin ships v0.107.71 (schema_version 32), which cannot parse a
  # config file written by v0.107.74. Pinning the package here keeps the nixpkgs
  # lock stable while unblocking the schema mismatch crash loop.
  adguardhome-v74 = pkgs.adguardhome.overrideAttrs (old: rec {
    version = "0.107.74";
    src = pkgs.fetchFromGitHub {
      owner = "AdguardTeam";
      repo = "AdGuardHome";
      tag = "v${version}";
      hash = "sha256-cAuthACY/rBVRTSv/UIarhScm+EoTUhnkQ0RUtvhAFg=";
    };
    vendorHash = "sha256-o4hpiqQEt8gkYFeAkxPDisvLWbi7WOBZ7xMXrPt6Cdo=";
    dashboard = old.dashboard.overrideAttrs (_: {
      inherit version src;
      npmDepsHash = "sha256-SOHmXvGLpjs8h0X+AJ6/jAYpxzoizhwRjIzx4SqJOCo=";
    });
    ldflags = [
      "-s"
      "-w"
      "-X github.com/AdguardTeam/AdGuardHome/internal/version.version=${version}"
    ];
    passthru = (old.passthru or { }) // { schema_version = 34; };
  });
in
{
  options.homelab.dns = {
    enable = mkEnableOption "AdGuard Home DNS server";

    upstreamDNS = mkOption {
      type = types.listOf types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
      description = "Upstream DNS servers";
    };

    adBlocking = mkOption {
      type = types.bool;
      default = true;
      description = "Enable ad blocking filters";
    };

    # TLS options for encrypted DNS
    tls = {
      enable = mkEnableOption "TLS for DNS-over-TLS (DoT) and DNS-over-HTTPS (DoH)";

      domain = mkOption {
        type = types.str;
        default = "dns.sammasak.dev";
        description = "Domain for DoT/DoH (must match ACME certificate)";
      };

      certFile = mkOption {
        type = types.path;
        default = "/var/lib/acme/dns.sammasak.dev/fullchain.pem";
        description = "Path to TLS certificate file";
      };

      keyFile = mkOption {
        type = types.path;
        default = "/var/lib/acme/dns.sammasak.dev/key.pem";
        description = "Path to TLS private key file";
      };

      dohPort = mkOption {
        type = types.port;
        default = 443;
        description = "Port for DNS-over-HTTPS (use 8443 if 443 is taken by ingress)";
      };

      dotPort = mkOption {
        type = types.port;
        default = 853;
        description = "Port for DNS-over-TLS (Android Private DNS uses this)";
      };
    };

    # DNS rewrites (wildcards supported)
    rewrites = mkOption {
      type = types.listOf (types.submodule {
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
      });
      default = [ ];
      description = "DNS rewrites for internal domain resolution";
      example = [
        { domain = "*.sammasak.dev"; answer = "192.168.10.200"; }
        { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }
      ];
    };
  };

  config = mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      package = adguardhome-v74;
      host = "0.0.0.0";
      port = 3003;
      openFirewall = true;
      # mutableSettings = true allows External-DNS (running in k3s) to write
      # filtering rules via the AdGuard API and have them persist across restarts.
      # NixOS-declared rewrites and settings are merged in on startup (taking precedence)
      # but runtime changes (External-DNS filtering rules) are preserved.
      mutableSettings = true;

      settings = {
        dns = {
          bind_hosts = [ "0.0.0.0" ];
          port = 53;
          upstream_dns = cfg.upstreamDNS;
          bootstrap_dns = [ "1.1.1.1" "8.8.8.8" ];
        };

        # TLS configuration for DoT and DoH
        tls = mkIf cfg.tls.enable {
          enabled = true;
          server_name = cfg.tls.domain;
          port_https = cfg.tls.dohPort;
          port_dns_over_tls = cfg.tls.dotPort;
          port_dns_over_quic = 0; # Disabled
          certificate_path = cfg.tls.certFile;
          private_key_path = cfg.tls.keyFile;
          allow_unencrypted_doh = false;
        };

        filtering = {
          filtering_enabled = cfg.adBlocking;
          protection_enabled = cfg.adBlocking;
          rewrites = map (r: {
            domain = r.domain;
            answer = r.answer;
            enabled = true;
          }) cfg.rewrites;
        };
      };
    };

    # Firewall rules
    networking.firewall = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = optionals cfg.tls.enable [ cfg.tls.dohPort cfg.tls.dotPort ];
    };

    # Ensure AdGuard Home starts after ACME certificates are available
    # and has permission to read them via SupplementaryGroups
    systemd.services.adguardhome = mkIf cfg.tls.enable {
      after = [ "acme-${cfg.tls.domain}.service" ];
      wants = [ "acme-${cfg.tls.domain}.service" ];
      serviceConfig.SupplementaryGroups = [ "acme" ];
    };
  };
}
