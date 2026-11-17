# Prometheus on black-pi through upstream services.prometheus: static scrapes of the host services, HTTPS probes of
# the public names through a loopback blackbox exporter, the rules in
# ./rules, the OTLP receiver alloy-otlp on acer pushes to (homelab-gitops#202), and alerts to ./alertmanager.nix.
# The whole file goes through configText, as the structured options emit no `otlp` or `storage` section; with it
# set, ruleFiles, scrapeConfigs and alertmanagers are not read. promtool checks it, rule files included, at build.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../../lib/firewall.nix lib) anySourceTcp mkDualBackendFirewall;
  inherit (config.sam.fleet) hosts;
  cfg = config.services.prometheus;
  fw = config.networking.firewall;
  address = hosts.${config.networking.hostName}.address;
  at = port: "${address}:${toString port}";
  static = job: targets: {
    job_name = job;
    static_configs = [ { inherit targets; } ];
  };
  probeBudget = 120;
  # the committed llm-bench scorecard as constant recording rules (pkgs/llm-bench/rules.nix)
  scorecard = ../../../pkgs/llm-bench/scorecard;
  # toFile, not writeText: a plain store file like ./rules/*.yaml, so evaluating black-pi's config on x86 (the gate
  # probe) never has to build an aarch64 derivation
  llmBench = builtins.toFile "llm-bench.yaml" (
    builtins.toJSON (
      import ../../../pkgs/llm-bench/rules.nix {
        inherit lib;
        hosts = lib.attrNames hosts;
        results = lib.mapAttrs (f: _: lib.importJSON (scorecard + "/${f}")) (
          lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix ".json" f) (builtins.readDir scorecard)
        );
      }
    )
  );
  # thresholds and windows from the policy file alone; the shipping collector runs on the deployer
  shipping = builtins.toFile "shipping.yaml" (
    builtins.toJSON (
      import ./rules/shipping.nix {
        inherit lib;
        policy = lib.importJSON ./shipping-policy.json;
        collectorNode = config.sam.fleet.deployer;
      }
    )
  );
  gpuHosts = lib.filterAttrs (_: h: h.gpu == "nvidia") hosts;
  blackbox = cfg.exporters.blackbox;
  # the public names as a browser reaches them, through Caddy on acer. Authentik's Postgres has no exporter, so a
  # dead Postgres shows as AppDown on auth.
  probes = {
    https_2xx = [
      "https://auth.sammasak.dev"
      "https://grafana.sammasak.dev"
      "https://ntfy.sammasak.dev/v1/health"
      "https://herman.sammasak.dev"
    ];
    # the ingress serves /v1 alone, behind a project key
    https_2xx_401 = [ "https://llm-gateway.sammasak.dev/v1/models" ];
    # forward auth sends a browser without a session to Authentik
    https_302_auth = [ "https://chat.sammasak.dev" ];
    # Caddy admits black-pi; without a bearer token Alloy refuses
    https_401_405 = [ "https://otlp.sammasak.dev/v1/logs" ];
  };
  https = codes: {
    prober = "http";
    timeout = "10s";
    http = {
      valid_status_codes = codes;
      fail_if_not_ssl = true;
      preferred_ip_protocol = "ip4";
    };
  };
in
{
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = pkgs.writeText "blackbox.yml" (
      builtins.toJSON {
        modules = {
          # [ ] is any 2xx
          https_2xx = https [ ];
          https_2xx_401 = https [
            200
            401
          ];
          https_302_auth = lib.recursiveUpdate (https [ 302 ]) {
            http = {
              follow_redirects = false;
              fail_if_header_not_matches = [
                {
                  header = "Location";
                  regexp = "^https://auth\\.sammasak\\.dev/";
                }
              ];
            };
          };
          # otlp: Alloy refuses a request without a bearer token
          https_401_405 = https [
            401
            405
          ];
        };
      }
    );
  };
  systemd.services.prometheus-blackbox-exporter.serviceConfig.MemoryMax = "64M";

  services.prometheus = {
    enable = true;
    listenAddress = address;
    retentionTime = "15d";
    extraFlags = [
      # the 15 d projection is 0.8 to 1.1 GB; the cap keeps the SD card's 3 GB root floor with Loki
      "--storage.tsdb.retention.size=1500MB"
      "--web.enable-otlp-receiver"
    ];
    configText = builtins.toJSON {
      global = {
        scrape_interval = "30s";
        evaluation_interval = "30s";
        external_labels.prometheus = config.networking.hostName;
      };
      # keeps the remote-write names, e.g. claude_code_cost_usage_USD_total
      otlp.translation_strategy = "UnderscoreEscapingWithSuffixes";
      # homelab-gitops#202: a replayed in-flight request lands behind newer ones; younger than this, kept
      storage.tsdb.out_of_order_time_window = "1m";
      # interpolated, not toString: the store copies are promtool's inputs
      rule_files = map (f: "${f}") [
        ./rules/general.yaml
        ./rules/node-exporter.yaml
        ./rules/alertmanager.yaml
        ./rules/prometheus.yaml
        ./rules/llm-gateway.yaml
        ./rules/homelab.yaml
        llmBench
        shipping
      ];
      alerting.alertmanagers = [
        { static_configs = [ { targets = [ (at config.services.prometheus.alertmanager.port) ]; } ]; }
      ];
      scrape_configs = [
        {
          # instance and node carry the host name, as the chart's relabelling did, for the mixin and the dashboards;
          # sleeps marks a host the fleet expects off at times, which ./rules/homelab.yaml keys on
          job_name = "node-exporter";
          scrape_timeout = "30s";
          # five unit_state series per unit, one of them failed: the rest would add thousands for no panel
          metric_relabel_configs = [
            {
              source_labels = [
                "__name__"
                "state"
              ];
              regex = "node_systemd_unit_state;(active|activating|deactivating|inactive)";
              action = "drop";
            }
          ];
          static_configs = lib.mapAttrsToList (name: h: {
            targets = [ "${h.address}:${toString cfg.exporters.node.port}" ];
            labels = {
              instance = name;
              node = name;
            }
            // lib.optionalAttrs h.sleeps { sleeps = "true"; };
          }) hosts;
        }
        {
          # 10 s: a GPU's load changes within seconds; one board is about 15 series
          job_name = "nvidia-gpu";
          scrape_interval = "10s";
          scrape_timeout = "8s";
          static_configs = lib.mapAttrsToList (name: h: {
            targets = [ "${h.address}:${toString cfg.exporters.nvidia-gpu.port}" ];
            labels = {
              instance = name;
              node = name;
            }
            // lib.optionalAttrs h.sleeps { sleeps = "true"; };
          }) gpuHosts;
        }
        (static "prometheus" [ (at cfg.port) ])
        (static "alertmanager" [ (at cfg.alertmanager.port) ])
        (static "grafana" [ (at config.services.grafana.settings.server.http_port) ])
        (static "loki" [ (at config.homelab.loki.port) ])
        # the admin listener, /metrics beside /status (modules/homelab/llm-gateway.toml)
        (static "llm-gateway" [ "${hosts.acer-swift.address}:9091" ])
        (static "alloy-otlp" [ "${hosts.acer-swift.address}:12346" ])
        (static "caddy" [ (lib.removePrefix "http://" config.sam.fleet.edgeMetrics.url) ])
      ]
      # Authentik's loopback listeners, through the edge's metrics site (edge.nix)
      ++ map
        (part: {
          job_name = "authentik-${part}";
          metrics_path = "/authentik/${part}/metrics";
          static_configs = [ { targets = [ (lib.removePrefix "http://" config.sam.fleet.edgeMetrics.url) ]; } ];
        })
        [
          "server"
          "worker"
        ]
      ++ [
        (static "blackbox-exporter" [ "${blackbox.listenAddress}:${toString blackbox.port}" ])
        {
          job_name = "blackbox";
          metrics_path = "/probe";
          static_configs = lib.mapAttrsToList (module: targets: {
            inherit targets;
            labels.__param_module = module;
          }) probes;
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "${blackbox.listenAddress}:${toString blackbox.port}";
            }
          ];
        }
      ];
    };
  };

  systemd.services.prometheus = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # about 20k series
    environment.GOMEMLIMIT = "400MiB";
    serviceConfig = {
      # a bad flag or a slow head load fails the switch instead of restarting unseen
      ExecStartPost = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 2 --retry 60 --retry-delay 2 --retry-all-errors --retry-max-time ${toString probeBudget} http://${at cfg.port}/-/ready";
      TimeoutStartSec = probeBudget + 30;
      RestartSec = 10;
      MemoryMax = "512M";
      MemorySwapMax = 0;
    };
  };

  # acer's alloy-otlp pushes OTLP; lenovo's watchdog and the harness usage report on either host read; Grafana on this
  # host arrives on loopback
  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "Prometheus: OTLP and queries from acer and lenovo.";
        ports = [ cfg.port ];
        sources = [
          hosts.acer-swift.address
          hosts.lenovo-21CB001PMX.address
        ];
        interfaces = [ ];
        inherit (fw) backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  assertions = [
    {
      assertion = fw.enable && anySourceTcp fw [ cfg.port ] == [ ];
      message = "modules/homelab/monitoring/prometheus.nix: Prometheus has no authentication and takes OTLP writes; keep the firewall on and port ${toString cfg.port} out of allowedTCPPorts.";
    }
    {
      assertion =
        cfg.scrapeConfigs == [ ] && cfg.ruleFiles == [ ] && cfg.rules == [ ] && cfg.alertmanagers == [ ];
      message = "modules/homelab/monitoring/prometheus.nix: configText is set, so services.prometheus.scrapeConfigs, ruleFiles, rules and alertmanagers are never read; add to the configText attrset instead.";
    }
  ];
}
