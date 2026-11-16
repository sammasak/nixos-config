# The *.sammasak.dev edge on acer (#420): Caddy terminates TLS with one DNS-01 wildcard from security.acme and
# proxies each name to its backend, with forward auth through the native Authentik (authentik.nix) for chat and
# grafana. The admin API answers only on a socket only caddy may write to, so no other local process can load a
# config without forward_auth; a config change or renewal reloads Caddy.
# herman is a static site from its Nix build.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) hosts;
  domain = "sammasak.dev";
  caddy = config.services.caddy;
  adminSocket = "unix//run/caddy/admin.sock|0200";
  # the native server and its embedded outpost (authentik.nix)
  authentik = "127.0.0.1:9000";
  # the only OTLP pushers: each host's native-otel-relay, and black-pi's blackbox probe
  otlpSources = map (h: hosts.${h}.address) [
    "lenovo-21CB001PMX"
    "acer-swift"
    "msi-ms7758"
    "asus-b460m"
    "black-pi"
  ];
  sites = {
    auth = "reverse_proxy ${authentik}";
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
    # herman's deploy/nginx.conf: hashed wasm/js/css that exist immutable and never the SPA fallback, the rest no-cache
    herman = ''
      root * ${pkgs.hermanWeb}
      @hashed {
        path *.wasm *.js *.css
        not path /sw.js
        file
      }
      header @hashed Cache-Control "public, max-age=31536000, immutable"
      header ?Cache-Control no-cache
      @spa {
        not path *.wasm *.js *.css /manifest.json /favicon.ico
        not file
      }
      rewrite @spa /index.html
      encode gzip
      file_server {
        precompressed gzip
      }
    '';
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
    # a TCP admin API would let any local process load a config; with none, a change restarts (every site drops)
    globalConfig = ''
      admin ${adminSocket}
      grace_period 10s
    '';
    # Caddy deletes a client-sent copy of each copied header before it sets the outpost's value.
    extraConfig = ''
      (authentik) {
        reverse_proxy /outpost.goauthentik.io/* ${authentik}
        forward_auth ${authentik} {
          uri /outpost.goauthentik.io/auth/caddy
          copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid
        }
      }
    '';
    virtualHosts =
      lib.mapAttrs' (
        name: extraConfig:
        lib.nameValuePair "${name}.${domain}" {
          useACMEHost = domain;
          inherit extraConfig;
        }
      ) sites
      // {
        # a name the wildcard DNS and certificate cover but no site serves, the apex too; Caddy's own answer would be an
        # empty 200. The default log name would carry the literal `*`
        "*.${domain}" = {
          serverAliases = [ domain ];
          useACMEHost = domain;
          logFormat = "output file ${config.services.caddy.logDir}/access-unserved.log";
          extraConfig = "respond 404";
        };
      };
  };

  systemd.services.caddy = {
    onFailure = [ "caddy-failed.service" ];
    serviceConfig.RuntimeDirectory = "caddy";
  };
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
      # lenovo's *.sammasak.dev rewrite and every OTLP relay send here by sam.fleet.edge
      assertion = config.networking.hostName == config.sam.fleet.edge;
      message = "modules/homelab/edge.nix runs on ${config.networking.hostName}, but sam.fleet.edge is ${config.sam.fleet.edge}: the DNS rewrite and the OTLP relays would point at the wrong host.";
    }
    {
      assertion =
        lib.filter (l: lib.hasPrefix "admin" l) (map lib.trim (lib.splitString "\n" caddy.globalConfig))
        == [
          "admin ${adminSocket}"
        ];
      message = "modules/homelab/edge.nix: keep Caddy's admin API on ${adminSocket} alone; any local process could otherwise load a config without forward_auth.";
    }
    {
      assertion =
        lib.hasInfix "\nX-Reload-Triggers=" config.systemd.units."caddy.service".text
        && !lib.elem caddy.configFile config.systemd.services.caddy.restartTriggers;
      message = "modules/homelab/edge.nix: a Caddyfile change must reload Caddy, not restart it (every site drops): the rendered caddy.service needs X-Reload-Triggers and the Caddyfile out of its restartTriggers.";
    }
  ];
}
