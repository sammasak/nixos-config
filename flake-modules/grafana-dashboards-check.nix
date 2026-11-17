# black-pi's dashboards, as grafana.nix provisions them, against what the fleet exports: the deployed node-exporter
# command runs on node_exporter's own sysfs/procfs fixtures, so its metric names are this version's with these flags;
# the GPU names are the gpu-telemetry-exporter check's output; records come from the rule files Prometheus loads.
# Each seeded dashboard below must fail scripts/check-grafana-dashboards.py with its own reason.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations) black-pi msi-ms7758;
  pi = black-pi.config;
  inherit (pi.homelab.grafana) dashboards;
  hosts = lib.attrNames pi.sam.fleet.hosts;
  discard = builtins.unsafeDiscardStringContext;
  prom = builtins.fromJSON (discard pi.services.prometheus.configText);
  jobs = map (c: c.job_name) prom.scrape_configs;
  nodesOf =
    job:
    lib.sort lib.lessThan (
      lib.concatMap (c: map (t: t.labels.node) c.static_configs) (
        lib.filter (c: c.job_name == job) prom.scrape_configs
      )
    );
  gpuHosts = lib.attrNames (lib.filterAttrs (_: h: h.gpu == "nvidia") pi.sam.fleet.hosts);
  # every fleet host runs the same exporter flags, so msi's command stands for each
  exporterHosts = lib.filterAttrs (
    _: h: h.config.services.prometheus.exporters.node.enable
  ) config.flake.nixosConfigurations;
  flagsOf =
    c: with c.services.prometheus.exporters.node; [
      extraFlags
      enabledCollectors
      disabledCollectors
    ];
  node = msi-ms7758.config.services.prometheus.exporters.node;
  exec = discard msi-ms7758.config.systemd.services.prometheus-node-exporter.serviceConfig.ExecStart;
  # a scraped job's own metrics, by prefix; the OTLP ones arrive through the receiver
  prefixes = {
    llm_gateway_ = "llm-gateway";
    loki_ = "loki";
    prometheus_ = "prometheus";
    alertmanager_ = "alertmanager";
    grafana_ = "grafana";
    probe_ = "blackbox";
    claude_code_ = "otlp";
    codex_ = "otlp";
  };
  otlp = lib.elem "--web.enable-otlp-receiver" pi.services.prometheus.extraFlags;
  builtin = [
    "up"
    "ALERTS"
    "ALERTS_FOR_STATE"
    "scrape_duration_seconds"
    "scrape_samples_scraped"
    "scrape_samples_post_metric_relabeling"
    "scrape_series_added"
  ];
  render =
    (import ../modules/homelab/monitoring/dashboards.nix {
      inherit lib;
      inherit (pi.sam.fleet) hosts;
    }).render;
  seed =
    expr: ds:
    render "seed.json" {
      uid = "seed";
      title = "seed";
      templating.list = [
        {
          name = "node";
          type = "custom";
        }
      ];
      panels = [
        {
          id = 1;
          type = "timeseries";
          title = "seed";
          gridPos = {
            h = 8;
            w = 12;
            x = 0;
            y = 0;
          };
          targets = [
            {
              refId = "A";
              inherit expr;
              datasource = {
                type = ds;
                uid = ds;
              };
            }
          ];
        }
      ];
    };
  seeds = {
    unknown-metric = {
      dashboard = seed "rate(node_no_such_metric_total[5m])" "prometheus";
      reason = "unknown metric node_no_such_metric_total";
    };
    # the systemd collector is off on every host, so a panel on it would stay empty
    collector-off = {
      dashboard = seed ''node_systemd_unit_state{node=~"$node",state="failed"}'' "prometheus";
      reason = "unknown metric node_systemd_unit_state";
    };
    unknown-host = {
      dashboard = seed ''up{node="no-such-host"}'' "prometheus";
      reason = ''host literal node="no-such-host"'';
    };
    fleet-host-by-hand = {
      dashboard = seed ''up{node="${lib.head hosts}"}'' "prometheus";
      reason = "host literal node=\"${lib.head hosts}\"";
    };
    loki-host-by-hand = {
      dashboard = seed ''{job="host-journal", host="no-such-host"}'' "loki";
      reason = ''host literal host="no-such-host"'';
    };
    bad-promql = {
      dashboard = seed "sum(rate(up[5m])" "prometheus";
      reason = "promtool:";
    };
    undefined-variable = {
      dashboard = seed ''up{node=~"$nosuch"}'' "prometheus";
      reason = "undefined variable $nosuch";
    };
    duplicate-uid = {
      dashboard = seed "up" "prometheus" // {
        uid = (lib.head (lib.attrValues dashboards)).uid;
      };
      reason = "duplicate uid";
    };
  };
  # a dashboard that lists the fleet variable's hosts itself fails evaluation
  handList = builtins.tryEval (
    builtins.deepSeq (render "bad.json" {
      templating.list = [
        {
          name = "node";
          type = "custom";
          query = "acer-swift";
        }
      ];
    }) true
  );
  promConfig = pi.services.prometheus.configText;
  # the rule files reach the build through configText's context; a derivation there would be an aarch64 build
  plainContext = lib.all (c: !(c ? outputs) && !(c.allOutputs or false)) (
    lib.attrValues (builtins.getContext promConfig)
  );
in
{
  perSystem =
    {
      system,
      pkgs,
      self',
      ...
    }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.grafana-dashboards =
        assert lib.assertMsg (nodesOf "node-exporter" == hosts)
          "grafana-dashboards: the node-exporter targets (${toString (nodesOf "node-exporter")}) are not the fleet's hosts (${toString hosts}), which the node variable lists";
        assert lib.assertMsg (nodesOf "nvidia-gpu" == gpuHosts)
          "grafana-dashboards: the nvidia-gpu targets are not the fleet's GPU hosts, which the gpu_node variable lists";
        assert lib.assertMsg
          (
            lib.all (n: exporterHosts ? ${n}) [
              "black-pi"
              "msi-ms7758"
            ]
            && lib.all (h: flagsOf h.config == flagsOf msi-ms7758.config) (lib.attrValues exporterHosts)
          )
          "grafana-dashboards: the hosts' node-exporter flags differ, so msi's output does not stand for every host";
        assert lib.assertMsg (lib.hasPrefix "${discard "${pkgs.prometheus-node-exporter}"}/bin/" (
          lib.trim exec
        )) "grafana-dashboards: msi's node-exporter is not this check's prometheus-node-exporter";
        assert lib.assertMsg (lib.all (j: j == "otlp" && otlp || lib.elem j jobs) (
          lib.attrValues prefixes
        )) "grafana-dashboards: a metric prefix names a job black-pi does not scrape";
        assert lib.assertMsg (
          !handList.success
        ) "grafana-dashboards: a dashboard listing the node variable's hosts by hand evaluated";
        assert lib.assertMsg plainContext
          "grafana-dashboards: black-pi's Prometheus configuration names a derivation";
        pkgs.runCommand "grafana-dashboards"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.curl
              pkgs.prometheus-node-exporter
            ];
            inherit promConfig;
            spec = builtins.toJSON {
              inherit dashboards hosts builtin;
              prefixes = lib.attrNames prefixes;
              inherit (prom) rule_files;
              record_sources = [ "${../pkgs/llm-bench/rules.nix}" ];
            };
            seeds = builtins.toJSON seeds;
            passAsFile = [
              "promConfig"
              "spec"
              "seeds"
            ];
          }
          ''
            src=${pkgs.prometheus-node-exporter.src}
            cp -r $src/collector/fixtures fixtures
            chmod -R u+w fixtures
            bash $src/ttar -C fixtures -x -f fixtures/sys.ttar
            bash $src/ttar -C fixtures -x -f fixtures/udev.ttar
            # the fixture predates Linux 3.14, which every host's kernel adds this line from
            echo 'MemAvailable:    1200000 kB' >> fixtures/proc/meminfo
            mkdir textfile
            echo 'homelab_check 1' > textfile/check.prom
            # the deployed command line, with only the listener, the textfile directory and the fixture roots swapped
            ${
              lib.replaceStrings
                [ "${node.listenAddress}:" "/run/node-exporter-textfile" ]
                [ "127.0.0.1:" "$PWD/textfile" ]
                (lib.replaceStrings [ "\\\n" "\n" ] [ " " " " ] exec)
            } --path.procfs=fixtures/proc --path.sysfs=fixtures/sys --path.udev.data=fixtures/udev/data > exporter.log 2>&1 &
            exporter=$!
            for _ in $(seq 50); do curl -fsS -o node.prom http://127.0.0.1:${toString node.port}/metrics && break; sleep 0.2; done
            kill "$exporter"
            grep -q '^node_cpu_seconds_total{' node.prom || {
              cat exporter.log
              echo "grafana-dashboards: node-exporter gave no CPU metrics on the fixtures" >&2
              exit 1
            }
            check() { python3 -I ${../scripts/check-grafana-dashboards.py} "$1" ${pkgs.prometheus.cli}/bin/promtool node.prom ${self'.checks.gpu-telemetry-exporter}; }
            check "$specPath"
            python3 -I ${../scripts/seed-grafana-dashboards.py} "$specPath" "$seedsPath"
            for s in seed-*.json; do
              reason=$(cat "''${s%.json}.reason")
              if check "$s" > "$s.out"; then
                echo "grafana-dashboards: $s passed" >&2
                exit 1
              fi
              grep -qF -- "$reason" "$s.out" || {
                cat "$s.out"
                echo "grafana-dashboards: $s failed, but not for: $reason" >&2
                exit 1
              }
              echo "$s fails: $reason"
            done > $out
            cat $out
          '';
    };
}
