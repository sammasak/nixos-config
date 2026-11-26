# What scripts/seventh-host-check.py reads for one host of a temporary tree: what it renders from the fleet, the
# assertions it fails and, with full, its toplevel there and in the unseeded copy (each its own nix eval, so one
# evaluator never holds more than one host twice).
{
  tree,
  host,
  seed,
  baseline ? null,
  full ? false,
  asserts ? full,
}:
let
  flake = builtins.getFlake tree;
  inherit (flake.inputs.nixpkgs) lib;
  c = flake.nixosConfigurations.${host}.config;
  failing = cfg: map (a: a.message) (builtins.filter (a: !a.assertion) cfg.assertions);
  guestsFailing =
    cfg:
    lib.concatMap (n: map (m: "containers.${n}: ${m}") (failing cfg.containers.${n}.config)) (
      lib.attrNames cfg.containers
    );
  # No assertion is part of the derivation, so a host failing one still has its toplevel's drvPath; the failures are
  # reported unmasked beside it. Guests too: a container's toplevel is in its host's.
  mask =
    { lib, ... }:
    {
      assertions = lib.mkForce [ ];
      sam.workers.guestModules = [ ({ lib, ... }: { assertions = lib.mkForce [ ]; }) ];
    };
  # extendModules is a second evaluation of the whole host: only a host that fails an assertion pays for it
  drv =
    f:
    if f.nixosConfigurations ? ${host} then
      let
        n = f.nixosConfigurations.${host};
      in
      if failing n.config == [ ] && guestsFailing n.config == [ ] then
        n.config.system.build.toplevel.drvPath
      else
        (n.extendModules { modules = [ mask ]; }).config.system.build.toplevel.drvPath
    else
      null;
  orEmpty = v: if v == null then [ ] else v;
  # black-pi renders Prometheus whole through configText (prometheus.nix asserts scrapeConfigs empty): read its
  # scrape_configs as prometheus.nix's own assertion does
  scrapeJobs =
    if c.services.prometheus.configText != null then
      (builtins.fromJSON (builtins.unsafeDiscardStringContext c.services.prometheus.configText))
      .scrape_configs or [ ]
    else
      c.services.prometheus.scrapeConfigs;
in
{
  inherit (c.networking) hostName;
  failing = if asserts then failing c else null;
  guestsFailing = if full then guestsFailing c else null;
  drv = if full then drv flake else null;
  baselineDrv = if full && baseline != null then drv (builtins.getFlake baseline) else null;

  firewall = {
    inherit (c.networking.firewall) backend extraCommands;
  };
  scrape = lib.optionals c.services.prometheus.enable (
    map (j: {
      job = j.job_name;
      targets = lib.concatMap (
        s:
        map (t: {
          target = t;
          instance = (if (s.labels or null) == null then { } else s.labels).instance or null;
        }) s.targets
      ) (orEmpty (j.static_configs or null));
    }) scrapeJobs
  );
  rewrites = lib.optionals c.services.adguardhome.enable (
    map (r: { inherit (r) domain answer; }) c.services.adguardhome.settings.filtering.rewrites
  );
  otlpSources = lib.optionals c.services.caddy.enable (
    lib.concatMap (v: lib.filter (lib.hasInfix "not remote_ip") (lib.splitString "\n" v.extraConfig)) (
      lib.attrValues c.services.caddy.virtualHosts
    )
  );
  dashboardsName =
    if c ? homelab.grafana.dashboards then
      lib.hasInfix ''"${seed}"'' (builtins.toJSON c.homelab.grafana.dashboards)
    else
      null;
  knownHost =
    if c.programs.ssh.knownHosts ? ${seed} then
      { inherit (c.programs.ssh.knownHosts.${seed}) hostNames publicKey; }
    else
      null;
  storeCache = c.sam.storeCache.enable;
  inherit (c.nix.settings) substituters;

  fleet = {
    hosts = lib.mapAttrs (_: h: [ h.address ] ++ h.extraAddresses) c.sam.fleet.hosts;
    lokiFrom = c.sam.fleet.loki.from;
    lokiPort = c.sam.fleet.loki.port;
  };
  deployNodes = lib.mapAttrs (_: n: {
    inherit (n) hostname;
    remoteBuild = n.profiles.system.remoteBuild or false;
  }) flake.deploy.nodes;
}
