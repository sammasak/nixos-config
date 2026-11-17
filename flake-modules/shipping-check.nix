# The shipping rules as black-pi's Prometheus loads them (rules/shipping.nix from the policy file): every metric they,
# the Shipping dashboard and the policy name is emitted or recorded (scripts/shipping-names.py), and a seeded unknown
# name in a rule and in a panel fails it; promtool runs alerts against inputs sized from the policy, so a threshold
# change keeps the test honest without editing it.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations) black-pi;
  policy = lib.importJSON ../modules/homelab/monitoring/shipping-policy.json;
  a = policy.alerts;
  collector = black-pi.config.sam.fleet.deployer;
  # the same file black-pi's Prometheus loads (asserted below), rebuilt here: its path there carries no context
  rules = builtins.toFile "shipping.yaml" (
    builtins.toJSON (
      import ../modules/homelab/monitoring/rules/shipping.nix {
        inherit lib policy;
        collectorNode = collector;
      }
    )
  );
  loaded =
    (builtins.fromJSON (
      builtins.unsafeDiscardStringContext black-pi.config.services.prometheus.configText
    )).rule_files;
  n = toString;
  tests = {
    # the copy without annotations, which promtool would otherwise compare word for word
    rule_files = [ "rules-test.json" ];
    evaluation_interval = "1m";
    tests = [
      {
        name = "gate fail rate: over the threshold on a full sample fires, on a short sample not";
        interval = "1m";
        input_series = [
          {
            series = "shipping_gate_fail_ratio";
            values = "${n (a.GateFailRateHigh.maxRatio.value + 0.1)}x90";
          }
          {
            series = "shipping_gate_runs_counted";
            values = "${n a.GateFailRateHigh.lastRuns.value}x40 ${
              n (a.GateFailRateHigh.lastRuns.value - 1)
            }x40";
          }
        ];
        alert_rule_test = [
          {
            alertname = "GateFailRateHigh";
            eval_time = "35m";
            exp_alerts = [
              {
                exp_labels = {
                  severity = "warning";
                  team = "shipping";
                };
              }
            ];
          }
          {
            alertname = "GateFailRateHigh";
            eval_time = "80m";
            exp_alerts = [ ];
          }
        ];
      }
      {
        name = "a host behind main pages after its up hours, a host that is off never";
        interval = "1m";
        input_series = [
          {
            series = ''shipping_deploy_lag_hours{host="msi-ms7758",node="msi-ms7758"}'';
            values = "${n (a.HostBehindMain.maxHours.value + 1)}x600";
          }
          {
            series = ''shipping_deploy_lag_hours{host="asus-b460m",node="asus-b460m"}'';
            values = "${n (a.HostBehindMain.maxHours.value + 1)}x600";
          }
          {
            series = ''up{job="node-exporter",node="msi-ms7758"}'';
            values = "1x600";
          }
          {
            series = ''up{job="node-exporter",node="asus-b460m"}'';
            values = "0x600";
          }
        ];
        alert_rule_test = [
          {
            alertname = "HostBehindMain";
            eval_time = "${n (a.HostBehindMain.upHours.value * 60 - 5)}m";
            exp_alerts = [ ];
          }
          {
            alertname = "HostBehindMain";
            eval_time = "${n (a.HostBehindMain.upHours.value * 60 + 5)}m";
            exp_alerts = [
              {
                exp_labels = {
                  severity = "warning";
                  team = "shipping";
                  host = "msi-ms7758";
                  node = "msi-ms7758";
                };
              }
            ];
          }
        ];
      }
      {
        name = "a collector that never wrote is stale, unless its host is down";
        interval = "1m";
        input_series = [
          {
            series = ''up{job="node-exporter",node="${collector}"}'';
            values = "1x40 0x40";
          }
        ];
        alert_rule_test = [
          {
            alertname = "ShippingCollectorStale";
            eval_time = "35m";
            exp_alerts = [
              {
                exp_labels = {
                  severity = "warning";
                  team = "shipping";
                };
              }
            ];
          }
          {
            alertname = "ShippingCollectorStale";
            eval_time = "80m";
            exp_alerts = [ ];
          }
        ];
      }
    ];
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        shipping-rules =
          assert lib.assertMsg (lib.elem (builtins.unsafeDiscardStringContext rules) loaded)
            "shipping-check: black-pi's Prometheus does not load ${rules}; rules/shipping.nix is called differently there";
          pkgs.runCommand "shipping-rules"
            {
              nativeBuildInputs = [
                pkgs.prometheus.cli
                pkgs.python3
                pkgs.jq
              ];
              tests = builtins.toJSON tests;
              passAsFile = [ "tests" ];
            }
            ''
              names=${../scripts/shipping-names.py}
              dash=${../modules/homelab/monitoring/dashboards/shipping.json}
              pol=${../modules/homelab/monitoring/shipping-policy.json}
              python3 -I ${../scripts/shipping-metrics.py} --list > emitted
              python3 -I $names emitted ${rules} $dash $pol
              jq '.groups[0].rules += [{record: "seeded", expr: "shipping_seeded_unknown > 1"}]' ${rules} > seeded-rule.json
              if python3 -I $names emitted seeded-rule.json $dash $pol; then echo "a rule naming an unknown metric passed" >&2; exit 1; fi
              jq '.panels[1].targets[0].expr = "shipping_seeded_unknown"' $dash > seeded-panel.json
              if python3 -I $names emitted ${rules} seeded-panel.json $pol; then echo "a panel naming an unknown metric passed" >&2; exit 1; fi
              jq '.groups[].rules[] |= del(.annotations)' ${rules} > rules-test.json
              cp "$testsPath" tests.yaml
              promtool test rules tests.yaml
              touch $out
            '';
      };
    };
}
