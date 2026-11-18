# The shipping rules (docs/shipping.md), every number from ../shipping-policy.json: the alerts, and per policy value
# its setting and the reading of the metric it is tuned by, for the Shipping dashboard's policy row. collectorNode is
# the host whose node-exporter serves the collector's textfile; its own outage is NodeChronicNotReady's page.
{
  lib,
  policy,
  collectorNode,
}:
let
  a = policy.alerts;
  actionable = ''shipping_issues_open{class="actionable"}'';
  at = i: if i == 0 then "sum(${actionable})" else "sum(${actionable} offset ${toString i}d)";
  alert =
    name: expr: summary: extra:
    {
      inherit expr;
      alert = name;
      # HostBehindMain alone has none: its upHours is its for
      "for" = "${toString a.${name}.forMinutes.value}m";
      labels = {
        severity = "warning";
        team = "shipping";
      };
      annotations = {
        inherit summary;
        description = "${summary} The threshold is in modules/homelab/monitoring/shipping-policy.json (alerts.${name}); change it by a PR that quotes the Shipping dashboard (docs/shipping.md).";
      };
    }
    // extra;
  # every leaf of the policy: { value, tunedBy } at a dotted path
  leaves = lib.collect (v: v ? tunedBy) (
    lib.mapAttrsRecursiveCond (v: !(v ? tunedBy)) (
      path: v: v // { path = lib.concatStringsSep "." path; }
    ) policy
  );
  setting = v: if builtins.isList v then toString (builtins.length v) else toString v;
in
{
  groups = [
    {
      name = "shipping.policy";
      rules = lib.concatMap (l: [
        {
          record = "shipping:policy_setting";
          expr = "vector(${setting l.value})";
          labels = {
            policy = l.path;
            tuned_by = l.tunedBy;
          };
        }
        {
          record = "shipping:policy_reading";
          expr = "max(${l.tunedBy})";
          labels.policy = l.path;
        }
      ]) leaves;
    }
    {
      name = "shipping.alerts";
      rules = [
        (alert "OpenIssuesGrowing"
          (lib.concatMapStringsSep " and " (i: "(${at i} - ${at (i + 1)}) > 0") (
            lib.range 0 (a.OpenIssuesGrowing.days.value - 1)
          ))
          "Open actionable issues grew on each of the last ${toString a.OpenIssuesGrowing.days.value} days."
          { }
        )
        (alert "PrLeadTimeHigh"
          ''shipping_pr_lead_time_hours{quantile="0.5"} > ${toString a.PrLeadTimeHigh.medianHours.value}''
          "The median PR lead time over the last 7 d is {{ $value | humanize }} h."
          { }
        )
        # an API-wide error leaves the prs section fresh, and the lead time quietly open-to-merge
        (alert "LeadTimeFallbacksHigh"
          ''sum(shipping_pr_lead_time_fallbacks{reason="http_error",window="7d"}) / sum(shipping_prs_merged{window="7d"}) > ${toString a.LeadTimeFallbacksHigh.maxRatio.value}''
          "{{ $value | humanizePercentage }} of the PRs merged in 7 d have their lead time from their open time: GitHub's commits API failed for them (journalctl -u shipping-metrics)."
          { }
        )
        (alert "ReviewFirstPassLow"
          "shipping_review_first_pass_ratio < ${toString a.ReviewFirstPassLow.minRatio.value} and on () shipping_review_prs_counted >= ${toString a.ReviewFirstPassLow.lastVerdicts.value}"
          "Only {{ $value | humanizePercentage }} of the last ${toString a.ReviewFirstPassLow.lastVerdicts.value} reviewed PRs passed their first review."
          { }
        )
        (alert "GateFailRateHigh"
          "shipping_gate_fail_ratio > ${toString a.GateFailRateHigh.maxRatio.value} and on () shipping_gate_runs_counted >= ${toString a.GateFailRateHigh.lastRuns.value}"
          "{{ $value | humanizePercentage }} of the last ${toString a.GateFailRateHigh.lastRuns.value} push gates failed."
          { }
        )
        # for: hours up and behind in a row, so a host that slept through a merge is not paged the minute it wakes
        (alert "HostBehindMain"
          ''shipping_deploy_lag_hours > ${toString a.HostBehindMain.maxHours.value} and on (node) up{job="node-exporter"} == 1''
          "{{ $labels.node }} runs a deploy {{ $value | humanize }} h behind main."
          { "for" = "${toString a.HostBehindMain.upHours.value}h"; }
        )
        (alert "DeployRolledBack"
          ''sum(shipping_deploy_rollbacks{window="24h"}) > ${toString a.DeployRolledBack.max.value}''
          "{{ $value }} deploy(s) rolled back in the last 24 h."
          { }
        )
        (alert "EscapeFound" ''sum(shipping_escapes{window="24h"}) > ${toString a.EscapeFound.max.value}''
          "{{ $value }} escape(s) in the last 24 h: a revert on a default branch or an issue labelled escape."
          { }
        )
        # min_over_time over 45 m spans two runs (every 30 min): one failed run that the next one fixes stays quiet
        (alert "ShippingCollectorStale"
          ''(time() - min(shipping_collector_success_timestamp_seconds) > ${
            toString (a.ShippingCollectorStale.maxHours.value * 3600)
          } or absent(shipping_collector_success_timestamp_seconds) or shipping_collector_authenticated < ${toString a.ShippingCollectorStale.minAuthenticated.value} or min_over_time(shipping_collector_section_failed[45m]) == 1) unless on () up{job="node-exporter", node="${collectorNode}"} == 0''
          "A shipping-metrics section on ${collectorNode} has not succeeded within ${toString a.ShippingCollectorStale.maxHours.value} h, failed two runs in a row (an error or the run deadline), or it ran without the owner's gh login and counted public repos only (journalctl -u shipping-metrics; gh auth status as the owner)."
          { }
        )
      ];
    }
  ];
}
