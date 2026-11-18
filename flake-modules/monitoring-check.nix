# black-pi's promtool (config and rule files), amtool and blackbox --config.check run only in its toplevel's build, so on
# the Pi at deploy. Seeded onto msi, an x86 host, the same modules' checked files build in the flake check; building it
# realises only those files and their tools, never a toplevel. The rule test below feeds the rendered modules/homelab/monitoring/rules/homelab.nix the
# node-exporter targets as the seed renders them, one case per host, so a host the fleet marks sleeps is checked.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations) black-pi msi-ms7758;
  modules = [
    # options only: prometheus.nix scrapes homelab.loki.port
    ../modules/homelab/loki.nix
    ../modules/homelab/monitoring/prometheus.nix
    ../modules/homelab/monitoring/alertmanager.nix
  ];
  seeded = (msi-ms7758.extendModules { inherit modules; }).config;
  failing = builtins.filter (a: !a.assertion) seeded.assertions;
  # a check switched off upstream or here would leave this derivation green and unchecked
  checksOn =
    c:
    c.services.prometheus.checkConfig == true
    && c.services.prometheus.alertmanager.checkConfig
    && c.services.prometheus.exporters.blackbox.enableConfigCheck
    && !c.services.prometheus.enableReload;
  s = seeded.systemd.services;
  units = [
    s.prometheus.serviceConfig.ExecStart
    s.alertmanager.serviceConfig.ExecStartPre
    s.prometheus-blackbox-exporter.serviceConfig.ExecStart
  ];

  nodeTargets = lib.concatMap (c: c.static_configs) (
    lib.filter (c: c.job_name == "node-exporter")
      (builtins.fromJSON (builtins.unsafeDiscardStringContext seeded.services.prometheus.configText))
      .scrape_configs
  );
  node = t: t.labels.node;
  sleeping = lib.attrNames (lib.filterAttrs (_: h: h.sleeps) seeded.sam.fleet.hosts);
  # the scrape label is what the rules read; the fleet fact is what a new host sets
  labelled = map node (lib.filter (t: t.labels.sleeps or "" == "true") nodeTargets);
  awake = lib.subtractLists sleeping (map node nodeTargets);
  # promtool's clock starts at the Unix epoch, a Thursday 00:00 UTC, inside msi's off window; 10:00 is outside it,
  # Saturday 12:00 inside again. A host with a fleet power window and no power.manualOff (msi) is planned off in it
  # alone (modules/homelab/monitoring/rules/homelab.nix); the other sleeping hosts are planned off at any time.
  night = "20m";
  day = "10h";
  saturday = "60h";
  homelabRules = import ../modules/homelab/monitoring/rules/homelab.nix {
    inherit lib;
    inherit (seeded.sam.fleet) hosts;
  };
  plannedByDay = h: !(homelabRules.windowed ? ${h});
  # a case at an instant (since the epoch, a Thursday 00:00 UTC) for one host, stated literally so the fleet facts and
  # the rule cannot drift together: the window's edges are 19:00 and 08:30 UTC, read after the alerts' for (2m planned, 15m outage)
  windowCase =
    name: at: host: planned:
    ruleTest name at [ host ] {
      HostExpectedOff = lib.optional planned host;
      NodeChronicNotReady = lib.optional (!planned) host;
    };
  ruleTest = name: at: down: firing: {
    inherit name;
    interval = "1m";
    input_series = map (t: {
      series = "up{${
        lib.concatStringsSep "," (
          lib.mapAttrsToList (k: v: "${k}=${builtins.toJSON v}") (t.labels // { job = "node-exporter"; })
        )
      }}";
      values = if lib.elem (node t) down then "0x3700" else "1x3700";
    }) nodeTargets;
    promql_expr_test = lib.mapAttrsToList (alertname: nodes: {
      expr = ''count by (node) (ALERTS{alertname="${alertname}",alertstate="firing"})'';
      eval_time = at;
      exp_samples = map (n: {
        labels = ''{node="${n}"}'';
        value = 1;
      }) nodes;
    }) firing;
  };
  ruleTests = {
    rule_files = [ homelabRules.file ];
    tests =
      lib.concatMap (h: [
        (ruleTest "${h} sleeps, off alone at night" night [ h ] {
          HostExpectedOff = [ h ];
          NodeChronicNotReady = [ ];
        })
        (ruleTest "${h} sleeps, off alone by day" day [ h ] {
          HostExpectedOff = lib.optional (plannedByDay h) h;
          NodeChronicNotReady = lib.optional (!plannedByDay h) h;
        })
      ]) sleeping
      ++ [
        (ruleTest "every sleeping host off at night" night sleeping {
          HostExpectedOff = sleeping;
          NodeChronicNotReady = [ ];
        })
        (ruleTest "every sleeping host off on a Saturday" saturday sleeping {
          HostExpectedOff = sleeping;
          NodeChronicNotReady = [ ];
        })
        # an unplanned outage among them fails open: no inhibit hides it behind the planned ones
        (ruleTest "every sleeping host off by day" day sleeping {
          HostExpectedOff = if lib.all plannedByDay sleeping then sleeping else [ ];
          NodeChronicNotReady = lib.filter (h: !plannedByDay h) sleeping;
        })
      ]
      ++ [
        (windowCase "msi off Thursday 10:00 UTC is an outage" "10h" "msi-ms7758" false)
        (windowCase "msi off Thursday 18:59 UTC is an outage" "18h59m" "msi-ms7758" false)
        (windowCase "msi off Thursday 19:05 UTC is planned" "19h5m" "msi-ms7758" true)
        (windowCase "msi off Friday 08:00 UTC is planned" "32h" "msi-ms7758" true)
        (windowCase "msi off Friday 08:46 UTC is an outage" "32h46m" "msi-ms7758" false)
        (windowCase "asus off Thursday 10:00 UTC is planned" "10h" "asus-b460m" true)
        (windowCase "asus off Friday 12:00 UTC is planned" "36h" "asus-b460m" true)
      ]
      ++ lib.concatMap (h: [
        (ruleTest "${h} does not sleep, off" night [ h ] {
          HostExpectedOff = [ ];
          NodeChronicNotReady = [ h ];
        })
        (ruleTest "${h} off with the sleeping hosts: fails open" night ([ h ] ++ sleeping) {
          HostExpectedOff = [ ];
          NodeChronicNotReady = [ h ];
        })
      ]) awake;
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        monitoring-config-msi-ms7758 = pkgs.writeText "monitoring-config-msi-ms7758" (
          assert lib.assertMsg (failing == [ ])
            "monitoring-check: the seeded msi fails ${toString (map (a: a.message) failing)}";
          assert lib.assertMsg (
            checksOn seeded && checksOn black-pi.config
          ) "monitoring-check: promtool, amtool or blackbox --config.check is off on black-pi or the seed";
          # the strings, not the options, are what this builds: upstream moving a checked file elsewhere would leave it green
          assert lib.assertMsg (lib.all ({ fst, snd }: lib.hasInfix snd fst) (
            lib.zipLists units [
              "-checkconfig-checked"
              "-checked-config"
              "-checked-blackbox-exporter.conf"
            ]
          )) "monitoring-check: a unit no longer references its checked config";
          # --log.level alone left the per-probe logger at info: a redirect line per probe in the journal (#529)
          assert lib.assertMsg
            (lib.all
              (
                f:
                lib.hasInfix f black-pi.config.systemd.services.prometheus-blackbox-exporter.serviceConfig.ExecStart
              )
              [
                "--log.level=warn"
                "--log.prober=warn"
              ]
            )
            "monitoring-check: black-pi's blackbox exporter does not run with --log.level=warn and --log.prober=warn";
          assert lib.assertMsg
            (
              seeded.services.prometheus.alertmanager.configuration
              == black-pi.config.services.prometheus.alertmanager.configuration
              && seeded.services.prometheus.extraFlags == black-pi.config.services.prometheus.extraFlags
            )
            "monitoring-check: black-pi's Alertmanager configuration or Prometheus flags differ from the seed's";
          lib.concatStringsSep "\n" units
        );
        monitoring-rules-sleeping-hosts =
          assert lib.assertMsg (sleeping != [ ] && lib.sort lib.lessThan labelled == sleeping)
            "monitoring-check: the node-exporter targets labelled sleeps (${toString labelled}) are not the fleet's sleeping hosts (${toString sleeping})";
          pkgs.runCommand "monitoring-rules-sleeping-hosts"
            {
              nativeBuildInputs = [ pkgs.prometheus.cli ];
              tests = builtins.toJSON ruleTests;
              passAsFile = [ "tests" ];
            }
            ''
              cp "$testsPath" tests.yaml
              promtool test rules tests.yaml
              touch $out
            '';
        # who an alert notifies: Alertmanager's own routing (amtool) on black-pi's configuration. A near-critical
        # sensor (notify="none") and an info alert reach no one; the paging temperature alert and a warning reach the bridge.
        monitoring-alert-routes =
          pkgs.runCommand "monitoring-alert-routes"
            {
              nativeBuildInputs = [ pkgs.prometheus-alertmanager ];
              config = builtins.toJSON black-pi.config.services.prometheus.alertmanager.configuration;
              passAsFile = [ "config" ];
            }
            ''
              route() {
                want=$1
                shift
                amtool config routes test --config.file="$configPath" --verify.receivers="$want" "$@"
              }
              route null alertname=NodeSensorNearCritical notify=none severity=warning team=homelab node=msi-ms7758
              route alert-bridge alertname=NodeTemperatureHigh severity=warning team=homelab node=black-pi
              route null alertname=NodeCPUHighUsage severity=info node=acer-swift
              route alert-bridge alertname=NodeMemoryHighUtilization severity=warning node=acer-swift
              # seeded: without the label the same alert would notify
              if route null alertname=NodeSensorNearCritical severity=warning team=homelab node=msi-ms7758; then
                echo "monitoring-alert-routes: the seed without notify=none reached no one" >&2
                exit 1
              fi
              touch $out
            '';
        # the alerts' own cases, beside the rule files they read (their rule_files path is relative); homelab.yaml as
        # Prometheus loads it, rendered
        monitoring-rules-tests =
          pkgs.runCommand "monitoring-rules-tests" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
            ''
              cp -r ${../modules/homelab/monitoring/rules} rules
              chmod -R u+w rules
              cd rules
              cp ${homelabRules.file} homelab.yaml
              cd tests
              for t in *.yaml; do promtool test rules "$t"; done
              touch $out
            '';
      };
    };
}
