# AdGuard Home DNS server with encrypted DNS support (DoT/DoH)
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.dns;
  inherit (lib) mkEnableOption mkOption mkIf types optionals;
  # Android Private DNS only speaks DoT on 853.
  dotPort = 853;
in
{
  options.homelab.dns = {
    enable = mkEnableOption "AdGuard Home DNS server";

    tls = {
      enable = mkEnableOption "TLS for DNS-over-TLS (DoT) and DNS-over-HTTPS (DoH)";

      domain = mkOption {
        type = types.str;
        default = "dns.sammasak.dev";
        description = "Domain for DoT/DoH (must match ACME certificate)";
      };

      dohPort = mkOption {
        type = types.port;
        default = 443;
        description = "Port for DNS-over-HTTPS (use 8443 if 443 is taken by ingress)";
      };
    };

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
      openFirewall = true;
      # mutableSettings = true allows External-DNS (running in k3s) to write
      # filtering rules via the AdGuard API and have them persist across restarts.
      # NixOS-declared rewrites and settings are merged in on startup (taking precedence)
      # but runtime changes (External-DNS filtering rules) are preserved.
      mutableSettings = true;

      settings = {
        http.address = "0.0.0.0:3003";
        dns = {
          bind_hosts = [ "0.0.0.0" ];
          port = 53;
          upstream_dns = [ "1.1.1.1" "8.8.8.8" ];
          bootstrap_dns = [ "1.1.1.1" "8.8.8.8" ];
        };

        tls = mkIf cfg.tls.enable {
          enabled = true;
          server_name = cfg.tls.domain;
          port_https = cfg.tls.dohPort;
          port_dns_over_tls = dotPort;
          port_dns_over_quic = 0; # Disabled
          certificate_path = "/var/lib/acme/${cfg.tls.domain}/fullchain.pem";
          private_key_path = "/var/lib/acme/${cfg.tls.domain}/key.pem";
          allow_unencrypted_doh = false;
        };

        filtering = {
          filtering_enabled = true;
          protection_enabled = true;
          rewrites = map (r: {
            domain = r.domain;
            answer = r.answer;
            enabled = true;
          }) cfg.rewrites;
        };
      };
    };

    networking.firewall = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = optionals cfg.tls.enable [ cfg.tls.dohPort dotPort ];
    };

    # Without the ACME group AdGuard cannot read its own certificate.
    systemd.services.adguardhome = mkIf cfg.tls.enable {
      after = [ "acme-${cfg.tls.domain}.service" ];
      wants = [ "acme-${cfg.tls.domain}.service" ];
      serviceConfig.SupplementaryGroups = [ "acme" ];
    };
  };
}
