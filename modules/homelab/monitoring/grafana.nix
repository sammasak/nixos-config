# grafana.sammasak.dev on black-pi through upstream services.grafana, reached through Caddy on acer. Sign-in
# through Authentik (generic_oauth, no proxy auth), and only through it: users and roles come with the first OIDC
# sign-in. The dashboards are the host ones in ./dashboards.
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
  # every dashboard parses at evaluation (importJSON throws), and each datasource reference anywhere in it (panels,
  # targets, templating, annotations) is a provisioned uid or a template variable; Grafana would only log the rest
  dashboards =
    lib.mapAttrs
      (
        f: _:
        builtins.addErrorContext "while parsing dashboards/${f}" (lib.importJSON (./dashboards + "/${f}"))
      )
      (lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix ".json" f) (builtins.readDir ./dashboards));
  provisioned = config.services.grafana.provision.datasources.settings.datasources;
  uids = map (d: d.uid or null) provisioned;
  # a legacy string datasource resolves by name too; the rest are Grafana's built-in sources
  known =
    uids
    ++ map (d: d.name) provisioned
    ++ [
      "-- Grafana --"
      "-- Mixed --"
      "-- Dashboard --"
      "grafana"
    ];
  refs =
    v:
    if builtins.isAttrs v then
      lib.optional (v ? datasource) v.datasource ++ lib.concatMap refs (builtins.attrValues v)
    else if builtins.isList v then
      lib.concatMap refs v
    else
      [ ];
  uidOf = d: if builtins.isAttrs d then d.uid or null else d;
  unknownUids = lib.concatLists (
    lib.mapAttrsToList (
      f: j:
      map (u: "${f}: ${u}") (
        lib.filter (u: u != null && !lib.hasPrefix "$" u && !lib.elem u known) (map uidOf (refs j))
      )
    ) dashboards
  );
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
        nftComment = "Grafana answers Caddy on the edge host.";
        ports = [ port ];
        # Caddy on the edge host (edge.nix)
        sources = [ hosts.${config.sam.fleet.edge}.address ];
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
    {
      assertion = unknownUids == [ ];
      message = "modules/homelab/monitoring/grafana.nix: dashboard datasources not provisioned (${toString uids}): ${lib.concatStringsSep ", " unknownUids}.";
    }
  ];
}
