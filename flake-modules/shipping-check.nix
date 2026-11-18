# The shipping rules as black-pi's Prometheus loads them (modules/homelab/monitoring/rules/shipping.nix from the policy file): every metric they,
# the Shipping dashboard and the policy name is emitted or recorded (scripts/shipping-names.py), and a seeded unknown
# name in a rule and in a panel fails it; promtool runs alerts against inputs and times sized from the policy's
# thresholds and for minutes, so a changed value keeps the test honest without editing it.
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
  gateFor = a.GateFailRateHigh.forMinutes.value;
  staleFor = a.ShippingCollectorStale.forMinutes.value;
  fallbackFor = a.LeadTimeFallbacksHigh.forMinutes.value;
  merged = 40;
  retroFor = a.RetroDueGateSlower.forMinutes.value;
  # a baseline gate median, and a rise far enough above factor x baseline to stay above the 7-d average it lifts
  gateBase = 600;
  gateRise = 2 * a.RetroDueGateSlower.factor.value * gateBase;
  # history: minutes before the rise (6 d clears the 5-d guard, 4 d does not); samples every 4 m, under the 5 m
  # lookback: 6 d of 1 m samples take promtool 14 s
  retroCase = name: history: fires: {
    inherit name;
    interval = "4m";
    input_series = [
      {
        series = ''shipping_gate_seconds{quantile="0.5"}'';
        values = "${n gateBase}x${n (history / 4 - 1)} ${n gateRise}x${n ((retroFor + 30) / 4)}";
      }
    ];
    alert_rule_test = [
      {
        alertname = "RetroDueGateSlower";
        eval_time = "${n (history + retroFor - 5)}m";
        exp_alerts = [ ];
      }
      {
        alertname = "RetroDueGateSlower";
        eval_time = "${n (history + retroFor + 5)}m";
        exp_alerts = lib.optional fires {
          exp_labels = {
            quantile = "0.5";
            severity = "warning";
            team = "shipping";
          };
        };
      }
    ];
  };
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
            values = "${n (a.GateFailRateHigh.maxRatio.value + 0.1)}x${n (2 * gateFor + 30)}";
          }
          {
            series = "shipping_gate_runs_counted";
            values = "${n a.GateFailRateHigh.lastRuns.value}x${n (gateFor + 10)} ${
              n (a.GateFailRateHigh.lastRuns.value - 1)
            }x${n (gateFor + 20)}";
          }
        ];
        alert_rule_test = [
          {
            alertname = "GateFailRateHigh";
            eval_time = "${n (gateFor + 5)}m";
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
            eval_time = "${n (gateFor + 25)}m";
            exp_alerts = [ ];
          }
        ];
      }
      {
        name = "lead time from open time on most merged PRs fires after its for and not before, under the ratio not";
        interval = "1m";
        input_series = [
          {
            series = ''shipping_prs_merged{window="7d"}'';
            values = "${n merged}x${n (2 * fallbackFor + 30)}";
          }
          # every PR also counted under another reason and another window: the rule must read 7 d http_error alone
          {
            series = ''shipping_pr_lead_time_fallbacks{reason="http_error",window="30d"}'';
            values = "${n merged}x${n (2 * fallbackFor + 30)}";
          }
          {
            series = ''shipping_pr_lead_time_fallbacks{reason="no_commits",window="7d"}'';
            values = "${n merged}x${n (2 * fallbackFor + 30)}";
          }
          {
            series = ''shipping_pr_lead_time_fallbacks{reason="http_error",window="7d"}'';
            values = "${n (merged * a.LeadTimeFallbacksHigh.maxRatio.value + 2)}x${n (fallbackFor + 10)} ${
              n (merged * a.LeadTimeFallbacksHigh.maxRatio.value - 2)
            }x${n (fallbackFor + 20)}";
          }
        ];
        alert_rule_test = [
          {
            alertname = "LeadTimeFallbacksHigh";
            eval_time = "${n (fallbackFor - 5)}m";
            exp_alerts = [ ];
          }
          {
            alertname = "LeadTimeFallbacksHigh";
            eval_time = "${n (fallbackFor + 5)}m";
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
            alertname = "LeadTimeFallbacksHigh";
            eval_time = "${n (fallbackFor + 25)}m";
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
        name = "a fresh collector without the owner's gh login pages, with it not";
        interval = "1m";
        input_series = [
          {
            series = ''up{job="node-exporter",node="${collector}"}'';
            values = "1x${n (2 * staleFor + 80)}";
          }
          {
            series = ''shipping_collector_success_timestamp_seconds{section="issues"}'';
            values = "0+60x${n (2 * staleFor + 80)}";
          }
          {
            series = "shipping_collector_authenticated";
            values = "${
              n (a.ShippingCollectorStale.minAuthenticated.value - 1)
            }x${n (staleFor + 10)} ${n a.ShippingCollectorStale.minAuthenticated.value}x${n (staleFor + 70)}";
          }
        ];
        alert_rule_test = [
          {
            alertname = "ShippingCollectorStale";
            eval_time = "${n (staleFor + 5)}m";
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
            eval_time = "${n (staleFor + 25)}m";
            exp_alerts = [ ];
          }
        ];
      }
      {
        name = "a section failing two runs in a row pages; one failed run the next one fixes does not";
        interval = "1m";
        input_series = [
          {
            series = ''up{job="node-exporter",node="${collector}"}'';
            values = "1x200";
          }
          {
            series = ''shipping_collector_success_timestamp_seconds{section="issues"}'';
            values = "0+60x200";
          }
          {
            series = "shipping_collector_authenticated";
            values = "1x200";
          }
          # deploys succeeds for an hour, then fails run after run
          {
            series = ''shipping_collector_section_failed{section="deploys"}'';
            values = "0x60 1x140";
          }
          # gates fails one run (30 min), then the next run succeeds
          {
            series = ''shipping_collector_section_failed{section="gates"}'';
            values = "0x60 1x30 0x110";
          }
        ];
        alert_rule_test = [
          {
            alertname = "ShippingCollectorStale";
            eval_time = "100m";
            exp_alerts = [ ];
          }
          {
            alertname = "ShippingCollectorStale";
            eval_time = "${n (60 + 45 + staleFor + 5)}m";
            exp_alerts = [
              {
                exp_labels = {
                  section = "deploys";
                  severity = "warning";
                  team = "shipping";
                };
              }
            ];
          }
        ];
      }
      (retroCase "gate median over factor x its 7-d average after 5 d of history fires after its for" (
        6 * 1440
      ) true)
      (retroCase "the same rise on under 5 d of history does not fire" (4 * 1440) false)
      {
        name = "a gate median at its own baseline does not fire";
        interval = "4m";
        input_series = [
          {
            series = ''shipping_gate_seconds{quantile="0.5"}'';
            values = "${n gateBase}x${n ((6 * 1440 + retroFor + 30) / 4)}";
          }
        ];
        alert_rule_test = [
          {
            alertname = "RetroDueGateSlower";
            eval_time = "${n (6 * 1440 + retroFor + 5)}m";
            exp_alerts = [ ];
          }
        ];
      }
      {
        name = "a collector that never wrote is stale, unless its host is down";
        interval = "1m";
        input_series = [
          {
            series = ''up{job="node-exporter",node="${collector}"}'';
            values = "1x${n (staleFor + 10)} 0x${n (staleFor + 20)}";
          }
        ];
        alert_rule_test = [
          {
            alertname = "ShippingCollectorStale";
            eval_time = "${n (staleFor + 5)}m";
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
            eval_time = "${n (staleFor + 25)}m";
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
            "shipping-check: black-pi's Prometheus does not load ${rules}; modules/homelab/monitoring/rules/shipping.nix is called differently there";
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
