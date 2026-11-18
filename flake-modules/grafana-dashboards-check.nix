# black-pi's dashboards, as grafana.nix provisions them, against what the fleet exports: the deployed node-exporter
# command runs on node_exporter's own sysfs/procfs fixtures, so its metric names are this version's with these
# flags; the GPU names are the gpu-telemetry-exporter check's output; records come from the rule files Prometheus
# loads; llm-gateway's from its registrations and Loki's, Alloy's, Caddy's and blackbox's from their name literals,
# in the source each host runs; the OTLP ones are alloy-otlp's allow-list. Each seeded dashboard below must fail
# scripts/check-grafana-dashboards.py with its own reason.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations)
    acer-swift
    black-pi
    lenovo
    msi-ms7758
    ;
  # its output holds what adguard-textfile wrote against a running AdGuard (modules/homelab/adguardhome.nix)
  adguardCheck =
    lib.findFirst (c: c.name == "adguardhome-fleet-names")
      (throw "grafana-dashboards: lenovo has no adguardhome-fleet-names check")
      lenovo.config.system.checks;
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
  # every fleet host runs the same exporter flags, so msi's command stands for each
  exporterHosts = lib.filterAttrs (
    _: h: h.config.services.prometheus.exporters.node.enable
  ) config.flake.nixosConfigurations;
  # a textfile directory adds only the metrics of its own files (shipping_* and agent_nav_* come from their collectors'
  # --list below), so those flags are left out of the comparison
  flagsOf =
    c: with c.services.prometheus.exporters.node; [
      (lib.filter (f: !lib.hasPrefix "--collector.textfile.directory=" f) extraFlags)
      enabledCollectors
      disabledCollectors
    ];
  node = msi-ms7758.config.services.prometheus.exporters.node;
  exec = discard msi-ms7758.config.systemd.services.prometheus-node-exporter.serviceConfig.ExecStart;
  acer = acer-swift.config;
  # the longest prefix first: Alloy's loki.write names sit inside Loki's
  sources = [
    {
      prefix = "loki_write_";
      strip = "";
      job = "alloy-otlp";
      src = acer-swift.pkgs.grafana-alloy.src;
    }
    {
      prefix = "loki_";
      strip = "loki_";
      job = "loki";
      src = msi-ms7758.pkgs.grafana-loki.src;
    }
    {
      prefix = "caddy_http_";
      strip = "caddy_http_";
      job = "caddy";
      src = acer-swift.pkgs.caddy.src;
    }
    {
      prefix = "probe_";
      strip = "";
      job = "blackbox";
      src = msi-ms7758.pkgs.prometheus-blackbox-exporter.src;
    }
  ];
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
    scrape-job-typo = {
      dashboard = seed ''up{job="node_exporter"}'' "prometheus";
      reason = "job 'node_exporter': no scrape job";
    };
    loki-job-typo = {
      dashboard = seed ''{job="journal"}'' "loki";
      reason = "job 'journal': no Loki stream";
    };
    # a rule on a metric nothing exports, as the remote-write alerts were
    rule-unknown-metric = {
      rules.groups = [
        {
          name = "seed";
          rules = [
            {
              alert = "SeedRemoteWriteBehind";
              expr = "prometheus_remote_storage_shards_desired > 0";
            }
          ];
        }
      ];
      reason = "rules rules-rule-unknown-metric SeedRemoteWriteBehind: unknown metric prometheus_remote_storage_shards_desired";
    };
    rule-unknown-job = {
      rules.groups = [
        {
          name = "seed";
          rules = [
            {
              alert = "SeedTargetDown";
              expr = ''up{job="kube-state-metrics"} == 0'';
            }
          ];
        }
      ];
      reason = "rules rules-rule-unknown-job SeedTargetDown: job 'kube-state-metrics': no scrape job";
    };
    # a name the running Prometheus does not export
    prometheus-typo = {
      dashboard = seed "prometheus_tsdb_head_seriez" "prometheus";
      reason = "unknown metric prometheus_tsdb_head_seriez:";
    };
    gateway-typo = {
      dashboard = seed "rate(llm_gateway_no_such_total[5m])" "prometheus";
      reason = "unknown metric llm_gateway_no_such_total";
    };
    # the counter is exported as llm_gateway_requests_total
    gateway-suffix = {
      dashboard = seed "rate(llm_gateway_requests[5m])" "prometheus";
      reason = "unknown metric llm_gateway_requests:";
    };
    probe-typo = {
      dashboard = seed ''probe_sucess{job="blackbox"}'' "prometheus";
      reason = "unknown metric probe_sucess:";
    };
    # agent_nav_repo_miss_ratio, from nav.prom
    nav-typo = {
      dashboard = seed "agent_nav_repo_mis_ratio" "prometheus";
      reason = "unknown metric agent_nav_repo_mis_ratio:";
    };
    # the pre-595 name: nvidia-smi now heads these fields clocks_event_reasons, and the exporter names from the header
    gpu-throttle-name = {
      dashboard = seed ''nvidia_smi_clocks_throttle_reasons_hw_thermal_slowdown{job="nvidia-gpu"}'' "prometheus";
      reason = "unknown metric nvidia_smi_clocks_throttle_reasons_hw_thermal_slowdown";
    };
    caddy-typo = {
      dashboard = seed "rate(caddy_http_requets_total[5m])" "prometheus";
      reason = "unknown metric caddy_http_requets_total";
    };
    loki-word = {
      dashboard = seed "loki_name" "prometheus";
      reason = "unknown metric loki_name:";
    };
    # behind --collector.systemd.enable-restarts-metrics, which no host sets
    systemd-flag-off = {
      dashboard = seed "increase(node_systemd_service_restart_total[1h])" "prometheus";
      reason = "unknown metric node_systemd_service_restart_total";
    };
    # the logind collector is off on every host, so a panel on it would stay empty
    collector-off = {
      dashboard = seed ''node_logind_sessions{node=~"$node"}'' "prometheus";
      reason = "unknown metric node_logind_sessions";
    };
    unknown-host = {
      dashboard = seed ''up{node="no-such-host"}'' "prometheus";
      reason = "host literal node='no-such-host'";
    };
    single-quoted-host = {
      dashboard = seed "up{node='no-such-host'}" "prometheus";
      reason = "host literal node='no-such-host'";
    };
    # a label the literal check does not know: only the scan for fleet names catches it
    fleet-host-by-hand = {
      dashboard = seed ''up{job="${lib.head hosts}"}'' "prometheus";
      reason = "fleet host ${lib.head hosts} named";
    };
    loki-host-by-hand = {
      dashboard = seed ''{job="host-journal", host="no-such-host"}'' "loki";
      reason = "host literal host='no-such-host'";
    };
    bad-logql = {
      dashboard = seed ''{job="host-journal"} | json | unwrap'' "loki";
      reason = "LogQL: ";
    };
    variable-query = {
      dashboard = lib.recursiveUpdate (seed "up" "prometheus") {
        templating.list = [
          {
            name = "node";
            type = "custom";
            query = "";
          }
          {
            name = "bad";
            type = "query";
            query = "label_values(node_bogus_metric, node)";
          }
        ];
      };
      reason = "unknown metric node_bogus_metric";
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
  providers = pi.services.grafana.provision.dashboards.settings.providers;
  provider = lib.head providers;
  etcDashboards = lib.filter (lib.hasPrefix "grafana-dashboards/") (lib.attrNames pi.environment.etc);
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
    let
      toplevel =
        name:
        pkgs.runCommand name { } ''
          mkdir $out
          echo "# ${name}" > $out/activate
          echo 26.11 > $out/nixos-version
        '';
      fakeSystem = toplevel "nixos-system-fake";
      otherSystem = toplevel "nixos-system-other";
      # as deploy-rs's lib.activate.custom wraps a toplevel for its profile
      activatable =
        top:
        pkgs.buildEnv {
          name = "activatable-${top.name}";
          paths = [
            top
            (pkgs.writeTextDir "deploy-rs-activate" "")
          ];
        };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.grafana-dashboards =
        assert lib.assertMsg (nodesOf "node-exporter" == hosts)
          "grafana-dashboards: the node-exporter targets (${toString (nodesOf "node-exporter")}) are not the fleet's hosts (${toString hosts}), which the node variable lists";
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
        assert lib.assertMsg
          (otlp && lib.all (j: lib.elem j jobs) ([ "llm-gateway" ] ++ map (s: s.job) sources))
          "grafana-dashboards: a metric source names a job black-pi does not scrape, or its OTLP receiver is off";
        assert lib.assertMsg
          (
            discard pi.services.loki.package.src.outPath == discard msi-ms7758.pkgs.grafana-loki.src.outPath
            && lib.hasPrefix (discard "${black-pi.pkgs.prometheus-blackbox-exporter}/bin/") (
              discard pi.systemd.services.prometheus-blackbox-exporter.serviceConfig.ExecStart
            )
            &&
              discard black-pi.pkgs.prometheus-blackbox-exporter.src.outPath
              == discard msi-ms7758.pkgs.prometheus-blackbox-exporter.src.outPath
            && discard pkgs.grafana-loki.src.outPath == discard msi-ms7758.pkgs.grafana-loki.src.outPath
            &&
              discard pi.services.prometheus.package.src.outPath == discard msi-ms7758.pkgs.prometheus.src.outPath
            &&
              discard pi.services.prometheus.alertmanager.package.src.outPath
              == discard msi-ms7758.pkgs.prometheus-alertmanager.src.outPath
            && lib.hasInfix (discard "${acer-swift.pkgs.grafana-alloy}/bin/alloy") (
              discard (toString acer.systemd.services.alloy-otlp.serviceConfig.ExecStart)
            )
            && lib.hasInfix (discard "${acer-swift.pkgs.caddy}/bin/caddy") (
              discard (toString acer.systemd.services.caddy.serviceConfig.ExecStart)
            )
            && lib.hasInfix (discard "${acer-swift.pkgs.llmGateway}/bin/") (
              discard acer.systemd.services.llm-gateway.serviceConfig.ExecStart
            )
          )
          "grafana-dashboards: black-pi's Loki (or this check's logcli), Prometheus, Alertmanager or blackbox exporter, acer's alloy-otlp, Caddy or llm-gateway is not the source this check reads";
        assert lib.assertMsg (
          !handList.success
        ) "grafana-dashboards: a dashboard listing the node variable's hosts by hand evaluated";
        assert lib.assertMsg (lib.all (c: c == "systemd") node.enabledCollectors)
          "grafana-dashboards: a collector beyond the defaults and systemd is on; the fixtures may not run it, so add its names as systemd's are";
        assert lib.assertMsg plainContext
          "grafana-dashboards: black-pi's Prometheus configuration names a derivation";
        pkgs.runCommand "grafana-dashboards"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.curl
              pkgs.prometheus-node-exporter
              pkgs.ripgrep
            ];
            inherit promConfig;
            amConfig = builtins.toJSON pi.services.prometheus.alertmanager.configuration;
            # with its context: acer's own config file, token wrapper and Alloy, all x86
            alloyExec = acer.systemd.services.alloy-otlp.serviceConfig.ExecStart;
            spec = builtins.toJSON {
              inherit dashboards hosts builtin;
              sources = lib.imap0 (i: s: {
                inherit (s) prefix strip;
                literals = "literals-${toString i}";
              }) sources;
              otlp_allowlist = "${../modules/homelab/monitoring/alloy-otlp.alloy}";
              scrape_jobs = jobs;
              loki_job_sources = [
                "${../modules/homelab/journal-collector.nix}"
                "${../modules/homelab/loki.nix}"
                "${../scripts/platform-record.sh}"
                "${../modules/homelab/monitoring/alloy-otlp.alloy}"
              ];
              inherit (prom) rule_files;
              # black-pi's alert and recording rules, held to the same names and jobs as the panels
              alert_rules = prom.rule_files;
              record_sources = [ "${../pkgs/llm-bench/rules.nix}" ];
            };
            seeds = builtins.toJSON seeds;
            passAsFile = [
              "promConfig"
              "amConfig"
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
            # the generation file every host writes at activation: deploy-rs's profile holds its activatable buildEnv
            # around the toplevel, so generation 27 must be found through it (the exporter reads this one)
            mkdir -p profiles
            ln -s ${activatable fakeSystem} profiles/system-27-link
            ln -s ${activatable otherSystem} profiles/system-26-link
            ln -s system-27-link profiles/system
            bash ${../scripts/nixos-textfile.sh} textfile ${fakeSystem} profiles
            # nixos-rebuild's profile holds the toplevel; booted into 3 while the profile is at 4
            mkdir -p rebuild booted
            ln -s ${fakeSystem} rebuild/system-3-link
            ln -s ${otherSystem} rebuild/system-4-link
            ln -s system-4-link rebuild/system
            bash ${../scripts/nixos-textfile.sh} booted ${fakeSystem} rebuild
            grep -qx 'homelab_nixos_generation 3' booted/nixos.prom || {
              cat booted/nixos.prom
              echo "grafana-dashboards: booted into generation 3, the writer did not say so" >&2
              exit 1
            }
            # systemd needs D-Bus, which the sandbox lacks: its names come from this version's collector source and flags
            python3 -I ${../scripts/node-exporter-collector-names.py} $src systemd ${
              lib.replaceStrings [ "\\\n" "\n" ] [ " " " " ] exec
            } > systemd.prom
            grep -q '^node_systemd_units ' systemd.prom
            # timex needs adjtimex, which the sandbox may refuse
            python3 -I ${../scripts/node-exporter-collector-names.py} $src timex >> systemd.prom
            # what the repo's own textfile writers print (open-webui's edge check, the generation file)
            rg --no-filename -o "printf '(homelab_[a-z_]+)" -r '$1 0' ${../modules} ${../scripts} | sort -u > writers.prom
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
            grep -qx 'homelab_nixos_generation 27' node.prom || {
              cat textfile/nixos.prom
              echo "grafana-dashboards: the exporter does not report generation 27 through deploy-rs's profile" >&2
              exit 1
            }
            grep -q '^node_cpu_seconds_total{' node.prom || {
              cat exporter.log
              echo "grafana-dashboards: node-exporter gave no CPU metrics on the fixtures" >&2
              exit 1
            }
            ${lib.concatImapStrings (i: s: ''
              rg --no-filename -o -g '*.go' -g '!*_test.go' -g '!vendor/' '"[a-z][a-z0-9_]*"' ${s.src} \
                | tr -d '"' | sort -u > literals-${toString (i - 1)}
            '') sources}
            python3 -I ${../scripts/llm-gateway-metric-names.py} ${acer-swift.pkgs.llmGateway.src} > llm-gateway.prom
            # lenovo's shipping textfile (modules/homelab/shipping-metrics.nix): the names its collector emits
            python3 -I ${../scripts/shipping-metrics.py} --list > shipping.prom
            # the devTools hosts' navigation textfile (modules/homelab/nav-metrics.nix)
            python3 -I ${../scripts/nav-metrics.py} --list > nav.prom
            mkdir stack
            bash ${../scripts/monitoring-exposition.sh} stack ${msi-ms7758.pkgs.prometheus} "$promConfigPath" \
              ${
                lib.escapeShellArg (
                  toString (
                    pi.services.prometheus.extraFlags
                    ++ [ "--storage.tsdb.retention.time=${pi.services.prometheus.retentionTime}" ]
                  )
                )
              } ${msi-ms7758.pkgs.prometheus-alertmanager} "$amConfigPath" \
              ${lib.escapeShellArg (toString pi.services.prometheus.alertmanager.extraFlags)} "$alloyExec"
            # Authentik's names from the Python package and the Go server acer runs
            python3 -I ${../scripts/authentik-metric-names.py} ${acer.systemd.services.authentik-worker.environment.PYTHONPATH} \
              ${lib.head (lib.splitString " " acer.systemd.services.authentik.serviceConfig.ExecStart)} > authentik.prom
            check() {
              ${
                pkgs.python3.withPackages (ps: [ ps.pyyaml ])
              }/bin/python3 -I ${../scripts/check-grafana-dashboards.py} "$1" ${pkgs.prometheus.cli}/bin/promtool \
                ${pkgs.grafana-loki}/bin/logcli node.prom systemd.prom writers.prom llm-gateway.prom authentik.prom ${adguardCheck}/dns.prom stack/*.prom shipping.prom nav.prom ${self'.checks.gpu-telemetry-exporter}
            }
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
      # a dashboard file dropped from the repo leaves /etc/grafana-dashboards at the next switch, and Grafana, as
      # black-pi configures its provider, deletes the dashboard; the seeded disableDeletion = true must keep it
      checks.grafana-dashboard-removal =
        assert lib.assertMsg
          (
            lib.length providers == 1
            && provider.options.path == "/etc/grafana-dashboards"
            && etcDashboards == map (f: "grafana-dashboards/${f}") (lib.attrNames dashboards)
          )
          "grafana-dashboard-removal: black-pi's provider does not read exactly its dashboards from /etc/grafana-dashboards";
        assert lib.assertMsg (pi.services.grafana.package.version == pkgs.grafana.version)
          "grafana-dashboard-removal: black-pi runs Grafana ${pi.services.grafana.package.version}, this check ${pkgs.grafana.version}";
        pkgs.runCommand "grafana-dashboard-removal"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.curl
            ];
            deployed = builtins.toJSON provider;
            seeded = builtins.toJSON (provider // { disableDeletion = true; });
            passAsFile = [
              "deployed"
              "seeded"
            ];
          }
          ''
            bash ${../scripts/test-grafana-dashboard-removal.sh} ${pkgs.grafana} "$deployedPath" gone > $out
            bash ${../scripts/test-grafana-dashboard-removal.sh} ${pkgs.grafana} "$seededPath" kept >> $out
            cat $out
          '';
    };
}
