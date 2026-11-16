# The *.sammasak.dev edge on acer (#420): Caddy terminates TLS with one DNS-01 wildcard from security.acme and
# proxies each name to its backend, with forward auth through the k3s Authentik for chat and grafana. The admin API is
# off, so no local process can load a config without forward_auth; a config change or renewal restarts Caddy.
# herman, karta and registry proxy to their pods' ClusterIPs until they move (step 2, PR 2).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) hosts;
  domain = "sammasak.dev";
  # The native Authentik (authentik.nix) first, the k3s one while it still runs: a refused connection marks the first
  # down, so starting or stopping the native units moves sign-in without a deploy, and stopping them is the rollback.
  # Drop the ClusterIP with the HelmRelease.
  authentik = "127.0.0.1:9000 10.43.238.182:80";
  upstreams = ''
    lb_policy first
    lb_try_duration 3s
    fail_duration 10s
  '';
  # the only OTLP pushers: each host's native-otel-relay, and black-pi's blackbox probe
  otlpSources = map (h: hosts.${h}.address) [
    "lenovo-21CB001PMX"
    "acer-swift"
    "msi-ms7758"
    "black-pi"
  ];
  sites = {
    auth = ''
      reverse_proxy ${authentik} {
        ${upstreams}
      }
    '';
    chat = ''
      route {
        import authentik
        reverse_proxy unix//run/open-webui-edge.sock
      }
    '';
    grafana = ''
      route {
        import authentik
        reverse_proxy ${hosts.black-pi.address}:3000
      }
    '';
    # the gateway's API listener (llm-gateway.nix); /v1 alone, as the ingress served
    llm-gateway = ''
      @api path /v1 /v1/*
      handle @api {
        reverse_proxy 127.0.0.1:8081
      }
      handle {
        respond 404
      }
    '';
    # alloy-otlp checks the bearer token itself
    otlp = ''
      @denied not remote_ip ${lib.concatStringsSep " " otlpSources}
      handle @denied {
        respond 403
      }
      handle {
        reverse_proxy 127.0.0.1:4318
      }
    '';
    ntfy = "reverse_proxy ${hosts.lenovo-21CB001PMX.address}:2586";
    herman = "reverse_proxy 10.43.114.35:8080";
    karta = "reverse_proxy 10.43.147.178:8080";
    # zot, for pulls until the pods go
    registry = "reverse_proxy 10.43.23.61:5000";
  };
in
{
  imports = [ ./acme.nix ];

  homelab.acme.enable = true;
  security.acme.certs.${domain}.extraDomainNames = [ "*.${domain}" ];

  services.caddy = {
    enable = true;
    # 80/tcp, 443/tcp and 443/udp on every interface
    openFirewall = true;
    enableReload = false;
    globalConfig = "admin off";
    # Caddy deletes a client-sent copy of each copied header before it sets the outpost's value.
    extraConfig = ''
      (authentik) {
        reverse_proxy /outpost.goauthentik.io/* ${authentik} {
          ${upstreams}
        }
        forward_auth ${authentik} {
          ${upstreams}
          uri /outpost.goauthentik.io/auth/caddy
          copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid
        }
      }
    '';
    virtualHosts = lib.mapAttrs' (
      name: extraConfig:
      lib.nameValuePair "${name}.${domain}" {
        useACMEHost = domain;
        inherit extraConfig;
      }
    ) sites;
  };

  systemd.services.caddy.onFailure = [ "caddy-failed.service" ];
  systemd.services.caddy-failed = {
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
    };
    script = ''
      ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 --retry-all-errors --retry-max-time 60 -H "Priority: high" -d "caddy failed on ${config.networking.hostName}: every *.${domain} name is down" ${lib.escapeShellArg config.sam.workers.ntfyUrl}
    '';
  };

  assertions = [
    {
      assertion =
        !config.services.caddy.enableReload && lib.hasInfix "admin off" config.services.caddy.globalConfig;
      message = "modules/homelab/edge.nix: keep Caddy's admin API off and enableReload false; any local process could otherwise load a config without forward_auth.";
    }
  ];
}
