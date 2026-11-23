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
  # failsMore: the fail ratio rises above its own 7-d average with the gate time; without it slower alone stays quiet
  retroCase = name: history: failsMore: fires: {
    inherit name;
    interval = "4m";
    input_series = [
      {
        series = ''shipping_gate_seconds{host="lenovo",quantile="0.5"}'';
        values = "${n gateBase}x${n (history / 4 - 1)} ${n gateRise}x${n ((retroFor + 30) / 4)}";
      }
      {
        series = ''shipping_gate_fail_ratio{host="lenovo"}'';
        values = "0.1x${n (history / 4 - 1)} ${
          if failsMore then "0.4" else "0.1"
        }x${n ((retroFor + 30) / 4)}";
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
            host = "lenovo";
            quantile = "0.5";
            severity = "warning";
            team = "shipping";
          };
        };
      }
    ];
  };
  stepFor = a.RetroDueStepFailsRepeat.forMinutes.value;
  minFails = a.RetroDueStepFailsRepeat.minFailures.value;
  lastRuns = a.RetroDueStepFailsRepeat.lastRuns.value;
  newFailFor = a.RetroDueStepFailsRepeat.newFailureHours.value;
  # check: the flake check's inner check ("" for a step-level count); failures: its 7-d count of heads; runs: the gate
  # sample behind it. A second check of the same step sits one under the threshold: checks are counted apart. No
  # last-failure series, as from an older collector: the count alone decides.
  stepCase = name: check: failures: runs: fires: {
    inherit name;
    interval = "1m";
    input_series = [
      {
        series = ''shipping_gate_step_failures{check="${check}",step="nixos-flake-check",window="7d"}'';
        values = "${n failures}x${n (stepFor + 20)}";
      }
      {
        series = ''shipping_gate_step_failures{check="checks.x86_64-linux.other",step="nixos-flake-check",window="7d"}'';
        values = "${n (minFails - 1)}x${n (stepFor + 20)}";
      }
      {
        series = ''shipping_gate_step_failures{step="lint",window="7d"}'';
        values = "1x${n (stepFor + 20)}";
      }
      {
        series = ''shipping_gate_runs_counted{host="lenovo"}'';
        values = "${n runs}x${n (stepFor + 20)}";
      }
    ];
    alert_rule_test = [
      {
        alertname = "RetroDueStepFailsRepeat";
        eval_time = "${n (stepFor - 5)}m";
        exp_alerts = [ ];
      }
      {
        alertname = "RetroDueStepFailsRepeat";
        eval_time = "${n (stepFor + 5)}m";
        exp_alerts = lib.optional fires {
          exp_labels = {
            step = "nixos-flake-check";
            severity = "warning";
            team = "shipping";
          }
          // lib.optionalAttrs (check != "") { inherit check; };
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
        name = "gate fail rate: over the threshold on a full sample of two hosts' runs fires, on a short sample not";
        interval = "1m";
        input_series = [
          {
            series = ''shipping_gate_fail_ratio{host="lenovo"}'';
            values = "${n (a.GateFailRateHigh.maxRatio.value + 0.1)}x${n (2 * gateFor + 30)}";
          }
          {
            series = ''shipping_gate_fail_ratio{host="acer-herman"}'';
            values = "${n (a.GateFailRateHigh.maxRatio.value + 0.1)}x${n (2 * gateFor + 30)}";
          }
          {
            series = ''shipping_gate_runs_counted{host="lenovo"}'';
            values = "${n (a.GateFailRateHigh.lastRuns.value / 2)}x${n (gateFor + 10)} ${
              n (a.GateFailRateHigh.lastRuns.value / 2 - 1)
            }x${n (gateFor + 20)}";
          }
          {
            series = ''shipping_gate_runs_counted{host="acer-herman"}'';
            values = "${n (a.GateFailRateHigh.lastRuns.value / 2)}x${n (2 * gateFor + 30)}";
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
      (retroCase
        "gate median over factor x its 7-d average, failing more, after 5 d of history fires after its for"
        (6 * 1440)
        true
        true
      )
      (retroCase "the same rise on under 5 d of history does not fire" (4 * 1440) true false)
      (retroCase "slower but failing no more than its 7-d average does not fire: long is not a retro" (
        6 * 1440
      ) false false)
      (stepCase "one step failing minFailures times over a full sample fires after its for" "" minFails
        lastRuns
        true
      )
      (stepCase "one step failing once less does not fire" "" (minFails - 1) lastRuns false)
      (stepCase "a short sample does not fire" "" minFails (lastRuns - 1) false)
      (stepCase "one inner check failing minFailures times fires, named by its check"
        "checks.x86_64-linux.grafana-dashboards"
        minFails
        lastRuns
        true
      )
      (stepCase
        "two checks of one step, each once under the threshold, do not fire: the umbrella is not summed"
        "checks.x86_64-linux.grafana-dashboards"
        (minFails - 1)
        lastRuns
        false
      )
      (
        let
          # the last failure at 0, the next one at repeatAt, the 7-d count at the threshold throughout
          repeatAt = newFailFor * 60 + 60;
          firing = [
            {
              exp_labels = {
                step = "nixos-flake-check";
                severity = "warning";
                team = "shipping";
              };
            }
          ];
          at = t: exp_alerts: {
            alertname = "RetroDueStepFailsRepeat";
            eval_time = "${n t}m";
            inherit exp_alerts;
          };
        in
        {
          name = "a pattern clears newFailureHours after its last failure, the count still at the threshold, and fires again on the next";
          interval = "1m";
          input_series = [
            {
              series = ''shipping_gate_step_failures{check="",step="nixos-flake-check",window="7d"}'';
              values = "${n minFails}x${n (repeatAt + stepFor + 20)}";
            }
            {
              series = ''shipping_gate_step_last_failure_timestamp_seconds{check="",step="nixos-flake-check"}'';
              values = "0x${n (repeatAt - 1)} ${n (repeatAt * 60)}x${n (stepFor + 20)}";
            }
            {
              series = ''shipping_gate_runs_counted{host="lenovo"}'';
              values = "${n lastRuns}x${n (repeatAt + stepFor + 20)}";
            }
          ];
          alert_rule_test = [
            (at (stepFor + 5) firing)
            (at (newFailFor * 60 - 5) firing)
            (at (newFailFor * 60 + 5) [ ])
            (at (repeatAt + stepFor - 5) [ ])
            (at (repeatAt + stepFor + 5) firing)
          ];
        }
      )
      {
        name = "a gate median at its own baseline does not fire";
        interval = "4m";
        input_series = [
          {
            series = ''shipping_gate_seconds{host="lenovo",quantile="0.5"}'';
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
      # a guest joins after 6 d of lenovo at its baseline, its gates far slower and failing from the first: no host has
      # risen over its own past, so nothing fires (against a fleet-wide average the join alone would)
      {
        name = "a new host slow and failing from the start fires nothing, and moves no other host";
        interval = "4m";
        input_series = [
          {
            series = ''shipping_gate_seconds{host="lenovo",quantile="0.5"}'';
            values = "${n gateBase}x${n ((6 * 1440 + retroFor + 30) / 4)}";
          }
          {
            series = ''shipping_gate_fail_ratio{host="lenovo"}'';
            values = "0.1x${n ((6 * 1440 + retroFor + 30) / 4)}";
          }
          {
            series = ''shipping_gate_seconds{host="acer-herman",quantile="0.5"}'';
            values = "_x${n (6 * 1440 / 4 - 1)} ${n (2 * gateRise)}x${n ((retroFor + 30) / 4)}";
          }
          {
            series = ''shipping_gate_fail_ratio{host="acer-herman"}'';
            values = "_x${n (6 * 1440 / 4 - 1)} 0.4x${n ((retroFor + 30) / 4)}";
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
