# grafana.sammasak.dev on black-pi through upstream services.grafana: Traefik on acer reaches it through a
# selectorless Service (homelab-gitops), and nothing else on the LAN does. Sign-in through Authentik (generic_oauth,
# no proxy auth) as the chart had it, and only through it. The database starts fresh: users and roles come back
# with the first OIDC sign-in, and the dashboards are the host ones in ./dashboards (the Kubernetes ones went with
# kube-state-metrics).
{ config, lib, ... }:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  fw = config.networking.firewall;
  address = hosts.${config.networking.hostName}.address;
  port = 3000;
  keys = [
    "admin_user"
    "admin_password"
    "oidc_client_id"
    "oidc_client_secret"
    "secret_key"
  ];
  file = key: "$__file{${config.sops.secrets."grafana/${key}".path}}";
  auth = "https://auth.sammasak.dev/application/o";
in
{
  sops.secrets = lib.genAttrs (map (k: "grafana/${k}") keys) (_: {
    sopsFile = ../../../secrets/homelab/grafana.yaml;
    owner = "grafana";
    mode = "0400";
    restartUnits = [ "grafana.service" ];
  });

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = address;
        http_port = port;
        domain = "grafana.sammasak.dev";
        root_url = "https://grafana.sammasak.dev";
      };
      # Grafana needs an admin to start and provision; nothing can sign in as it (below)
      security = {
        admin_user = file "admin_user";
        admin_password = file "admin_password";
        secret_key = file "secret_key";
      };
      # OIDC only: no login form, no basic auth. No local fallback either: with Authentik down, so is Grafana.
      auth.disable_login_form = true;
      "auth.basic".enabled = false;
      "auth.generic_oauth" = {
        enabled = true;
        name = "Authentik";
        allow_sign_up = true;
        auto_login = true;
        client_id = file "oidc_client_id";
        client_secret = file "oidc_client_secret";
        scopes = "openid email profile groups";
        auth_url = "${auth}/authorize/";
        token_url = "${auth}/token/";
        api_url = "${auth}/userinfo/";
        # Authentik sends no email for users without one (the owner account); without a fallback Grafana probes
        # <api_url>/emails and 404s.
        email_attribute_path = "email || join('', [preferred_username, '@users.sammasak.dev'])";
        login_attribute_path = "preferred_username";
        # members of Authentik's grafana-admins group are org Admin, anyone else Viewer
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'";
        use_pkce = true;
      };
    };
    provision = {
      enable = true;
      # the chart's uids, which every dashboard names
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus";
            url = "http://${address}:${toString config.services.prometheus.port}";
            access = "proxy";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            uid = "loki";
            url = "http://${address}:${toString config.homelab.loki.port}";
            access = "proxy";
          }
        ];
      };
      dashboards.settings.providers = [
        {
          name = "homelab";
          folder = "Observability";
          disableDeletion = true;
          options.path = "${./dashboards}";
        }
      ];
    };
  };

  systemd.services.grafana = {
    environment.GOMEMLIMIT = "320MiB";
    serviceConfig = {
      # the pod peaked at 354 MB without its sidecars
      MemoryMax = "384M";
      # DHCP: .137 can appear after the unit, and upstream's Restart=on-failure would spend its start limit at once
      RestartSec = 10;
      MemorySwapMax = 0;
    };
  };

  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "Grafana answers Caddy on acer.";
        ports = [ port ];
        # Caddy on acer (edge.nix)
        sources = [ hosts.acer-swift.address ];
        interfaces = [ ];
        inherit (fw) backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  assertions = [
    {
      assertion =
        let
          s = config.services.grafana.settings;
        in
        s.auth.disable_login_form
        && !s."auth.basic".enabled
        && !(s."auth.proxy".enabled or false)
        && !(s."auth.anonymous".enabled or false);
      message = "modules/homelab/monitoring/grafana.nix: keep the login form, basic, proxy and anonymous auth off; the admin password copied from the cluster is weak, and sign-in goes through Authentik.";
    }
    {
      assertion = config.sam.hostSecrets.enable;
      message = "modules/homelab/monitoring/grafana.nix: its credentials are sops secrets; set sam.hostSecrets.enable.";
    }
    {
      assertion = !config.services.grafana.openFirewall && fw.enable && anySourceTcp fw [ port ] == [ ];
      message = "modules/homelab/monitoring/grafana.nix: keep the firewall on and port ${toString port} out of openFirewall and allowedTCPPorts; admit a caller with a source-scoped rule.";
    }
  ];
}
