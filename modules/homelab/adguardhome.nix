# AdGuard Home DNS server with wildcard DNS for homelab
# Supports optional TLS for DNS-over-TLS (DoT) and DNS-over-HTTPS (DoH)
{ config, lib, ... }:
let
  cfg = config.homelab.dns;
  inherit (lib) mkEnableOption mkOption mkIf types optionals;
in
{
  options.homelab.dns = {
    enable = mkEnableOption "AdGuard Home DNS server";

    ingressIP = mkOption {
      type = types.str;
      description = "IP address for wildcard DNS rewrites";
      example = "192.168.10.154";
    };

    domain = mkOption {
      type = types.str;
      default = "homelab.lan";
      description = "Domain suffix for wildcard DNS (avoid .local - reserved for mDNS)";
    };

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

    # Additional DNS rewrites beyond the default homelab.lan
    extraRewrites = mkOption {
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
      description = "Additional DNS rewrites for external domains";
      example = [
        { domain = "*.sammasak.dev"; answer = "192.168.10.154"; }
        { domain = "sammasak.dev"; answer = "192.168.10.154"; }
      ];
    };
  };

  config = mkIf cfg.enable {
    services.adguardhome = {
      enable = true;
      host = "0.0.0.0";
      port = 3003;
      openFirewall = true;
      mutableSettings = false;

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
          # Combine default homelab.lan rewrites with extraRewrites
          rewrites = [
            { domain = "*.${cfg.domain}"; answer = cfg.ingressIP; enabled = true; }
            { domain = cfg.domain; answer = cfg.ingressIP; enabled = true; }
          ] ++ (map (r: {
            domain = r.domain;
            answer = r.answer;
            enabled = true;
          }) cfg.extraRewrites);
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
