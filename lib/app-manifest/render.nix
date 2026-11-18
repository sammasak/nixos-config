# The edge's site for each admitted ingress name and black-pi's scrape of each app's metrics, from `admit`'s output
# alone. Every value written into the Caddyfile is one a type bounds (app name, DNS label, HTTP path, auth enum)
# or the store path checked below, so an app cannot place a directive. An auth other than public imports the edge's
# own snippet of that name (edge.nix's extraConfig, as chat and grafana do); admission refuses one the edge lacks.
{
  lib,
  facts,
  granted,
  package,
}:
let
  storePath = "/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+";
  root =
    n:
    let
      p = package n;
    in
    if builtins.match storePath p == null then
      throw "app-manifest render: apps.${n}'s package ${builtins.toJSON p} is not a store path."
    else
      p;
  upstream = a: "unix/${a.socket}";
  block = head: directives: "${head} {\n${lib.concatMapStrings (d: "\t${d}\n") directives}}\n";
  lines = text: lib.splitString "\n" (lib.removeSuffix "\n" text);
  body =
    n: a: auth:
    # route keeps the written order, so forward_auth runs before the handler
    block "route" (
      lib.optional (auth != "public") "import ${auth}"
      ++ (
        if a ? socket then
          [ "reverse_proxy ${upstream a}" ]
        else
          [ "root * ${root n}" ]
          ++ lib.optional a.static.spa "try_files {path} /index.html"
          ++ [ "file_server" ]
      )
    );
  sites = lib.concatMapAttrs (n: a: lib.mapAttrs (_: auth: { inherit n a auth; }) a.ingress) granted;
  scraped = lib.filterAttrs (_: a: (a.metricsPath or null) != null) granted;
  metricsPath = n: "/apps/${n}/metrics";
in
rec {
  # services.caddy.virtualHosts entries, shaped as edge.nix's
  virtualHosts = lib.mapAttrs (_: s: {
    useACMEHost = facts.domain;
    extraConfig = body s.n s.a s.auth;
  }) sites;
  # handles for the edge's plain-HTTP metrics site, beside its /authentik/<part>/metrics ones
  metricsHandles = lib.concatStrings (
    lib.mapAttrsToList (
      n: a:
      block "handle ${metricsPath n}" [
        "rewrite * ${a.metricsPath}"
        "reverse_proxy ${upstream a}"
      ]
    ) scraped
  );
  # entries for prometheus.nix's scrape_configs: one target per app, all through the edge's metrics site
  scrapeConfigs = lib.optional (scraped != { }) {
    job_name = "apps";
    # the app decides its series; a scrape above this fails instead of growing black-pi's head
    sample_limit = 10000;
    static_configs = lib.mapAttrsToList (n: a: {
      targets = [ (lib.removePrefix "http://" facts.edgeMetrics.url) ];
      labels = {
        __metrics_path__ = metricsPath n;
        app = n;
        inherit (a) owner;
        node = a.host;
      };
    }) scraped;
  };
  # what the check compares and validates: each site as its Caddyfile block, then the metrics site
  caddyfile =
    lib.concatStrings (lib.mapAttrsToList (fqdn: v: block fqdn (lines v.extraConfig)) virtualHosts)
    + lib.optionalString (scraped != { }) (
      block "http://:${toString facts.edgeMetrics.port}" (lines metricsHandles)
    );
}
