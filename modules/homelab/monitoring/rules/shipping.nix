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
  gateMedian = ''shipping_gate_seconds{quantile="0.5"}'';
  # the gate series are per host; the fleet's fail ratio and sample are their run-weighted sums
  gateRuns = "sum(shipping_gate_runs_counted)";
  gateFailRatio = "sum(shipping_gate_fail_ratio * shipping_gate_runs_counted) / ${gateRuns}";
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
        # the alert's own expression: run, it returns each series past its threshold, with its value
        query = expr;
        runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/shipping.md#alerts";
      };
    }
    // extra;
  # every leaf of the policy: { value, tunedBy } at a dotted path
  leaves = lib.collect (v: v ? tunedBy) (
    lib.mapAttrsRecursiveCond (v: !(v ? tunedBy)) (
      path: v: v // { path = lib.concatStringsSep "." path; }
    ) policy
  );
  untouchedDays = a.OpenIssuesUntouched.days.value;
  parkedOut = lib.concatMapStringsSep " " (r: "-repo:sammasak/${r}") policy.issues.parkedRepos.value;
  # the one command that reruns a failed step alone, from its step and check labels: a check inside the flake check
  # by its attribute (one with a dot: flake-output-kinds and the step's other guards rerun the step), any other recorded
  # step by nixos:step; "unrecorded" failed before its first step
  rerun = ''{{ if eq $labels.step "unrecorded" }}devenv tasks run nixos:qa{{ else if and (match "[.]" $labels.check) (eq $labels.step "nixos-flake-check") }}nix build -L .#{{ $labels.check }}{{ else }}NIXOS_STEP={{ $labels.step }} devenv tasks run nixos:step{{ end }}'';
  setting = v: if builtins.isList v then toString (builtins.length v) else toString v;
  quietHours =
    let
      d = policy.notify.quietUntilUtcHour.value - policy.notify.quietFromUtcHour.value;
    in
    if d < 0 then d + 24 else d;
  newFailureHours =
    let
      h = a.RetroDueStepFailsRepeat.newFailureHours.value;
    in
    # muted shipping alerts are sent when the night ends only if still firing: a shorter window drops a night's failure
    assert lib.assertMsg
      (builtins.isInt h && h > quietHours + a.RetroDueStepFailsRepeat.forMinutes.value / 60.0)
      "shipping-policy.json: RetroDueStepFailsRepeat.newFailureHours ${toString h} is not a whole number of hours over the ${toString quietHours} h quiet hours";
    h;
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
        (alert "OpenIssuesUntouched"
          "sum(shipping_issues_untouched) > ${toString a.OpenIssuesUntouched.max.value}"
          "{{ $value }} open actionable issues have had no update for ${toString untouchedDays} d. List them with gh search issues --owner sammasak --state open --archived=false --updated \"<$(date -u -d -${toString untouchedDays}days +%FT%TZ)\" --sort updated --order asc -- ${parkedOut}, then close, park or work each."
          { }
        )
        (alert "PrLeadTimeHigh"
          ''shipping_pr_lead_time_hours{quantile="0.5"} > ${toString a.PrLeadTimeHigh.medianHours.value}''
          "The median PR lead time over the last 7 d is {{ $value | humanize }} h. The Shipping dashboard (https://grafana.sammasak.dev/d/shipping, where a PR's time goes) names the phase that waits; list the open PRs oldest first with gh search prs --owner sammasak --state open --sort created --order asc and merge, close or unblock the oldest."
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
          "Only {{ $value | humanizePercentage }} of the last ${toString a.ReviewFirstPassLow.lastVerdicts.value} reviewed PRs passed their first review. List them with gh search prs --owner sammasak --merged --sort updated --limit ${
            toString (2 * a.ReviewFirstPassLow.lastVerdicts.value)
          } and read what each first review found (gh pr view URL --comments); the Shipping dashboard (https://grafana.sammasak.dev/d/shipping, review rounds) shows the trend. A retro names the finding that repeats."
          { }
        )
        (alert "GateFailRateHigh"
          "${gateFailRatio} > ${toString a.GateFailRateHigh.maxRatio.value} and on () ${gateRuns} >= ${toString a.GateFailRateHigh.lastRuns.value}"
          "{{ $value | humanizePercentage }} of the last ${toString a.GateFailRateHigh.lastRuns.value} push gates failed. The Shipping dashboard (https://grafana.sammasak.dev/d/shipping, failed gate steps, last 7 d, and gate fail rate) names the step and host; rerun that step alone on main with NIXOS_STEP=STEP devenv tasks run nixos:step (for nixos-push-eval: nix flake show --all-systems), and fix what it names before the next push."
          { }
        )
        # the full gate runs on main only, on a schedule (modules/homelab/scheduled-gate.nix): a red run names its first
        # failed step and the commits since the last green head, the range a bisect starts from
        (lib.recursiveUpdate
          (alert "ScheduledGateRed"
            ''max by (node, head, step, check, green) (homelab_scheduled_gate_red{job="node-exporter"}) == 1''
            "The scheduled full gate failed on main at {{ $labels.head }}, first failed step {{ $labels.step }}{{ if $labels.check }}, check {{ $labels.check }}{{ end }}; {{ if eq $labels.green \"none\" }}no scheduled run has passed yet, so the range starts at the first scheduled run{{ else }}the commits since the last green run are {{ $labels.green }}..{{ $labels.head }}{{ end }}. Rerun it alone in a checkout of {{ $labels.head }}: ${rerun}; the run's log is journalctl -u scheduled-gate -n 200 on acer. A red head runs once more by itself; a later scheduled run that passes clears this."
            { }
          )
          {
            annotations.runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/shipping.md#scheduledgatered";
          }
        )
        # a stale check time covers a scheduler that stopped reading main: then behind no longer says whether it moved
        (lib.recursiveUpdate
          (alert "ScheduledGateOverdue"
            (
              let
                limit = toString (a.ScheduledGateOverdue.hours.value * 3600);
                s = m: ''max by (node) (${m}{job="node-exporter"})'';
              in
              "time() - ${s "homelab_scheduled_gate_behind_since_timestamp_seconds"} > ${limit} and on (node) ${s "homelab_scheduled_gate_behind_since_timestamp_seconds"} > 0 or time() - ${s "homelab_scheduled_gate_checked_timestamp_seconds"} > ${limit}"
            )
            "Main moved {{ $value | humanizeDuration }} ago and no scheduled full gate on {{ $labels.node }} has finished since, over ${toString a.ScheduledGateOverdue.hours.value} h, or the scheduler has not read main for that long. On acer: systemctl list-timers scheduled-gate and journalctl -u scheduled-gate -n 50."
            { }
          )
          {
            annotations.runbook_url = "https://github.com/sammasak/nixos-config/blob/main/docs/shipping.md#scheduledgateoverdue";
          }
        )
        # for: hours up and behind in a row, so a host that slept through a merge is not paged the minute it wakes
        (alert "HostBehindMain"
          ''shipping_deploy_lag_hours > ${toString a.HostBehindMain.maxHours.value} and on (node) up{job="node-exporter"} == 1''
          "{{ $labels.node }} runs a deploy {{ $value | humanize }} h behind main. From lenovo: just dry-activate HOST, then just deploy HOST (HOST is the flake attribute: lenovo for lenovo-21CB001PMX; msi and asus only in their power window)."
          { "for" = "${toString a.HostBehindMain.upHours.value}h"; }
        )
        # per host, and only until a good deploy of it: a rollback the retry fixed is handled
        (alert "DeployRolledBack"
          ''max by (host, node) (shipping_deploy_rollbacks_open{window="24h"}) > ${toString a.DeployRolledBack.max.value}''
          "{{ $value }} deploy(s) of {{ $labels.host }} rolled back in the last 24 h and none has succeeded since. Fix what its deploy output names, then from lenovo: just deploy {{ $labels.host }}; a good deploy clears this."
          { }
        )
        (alert "EscapeFound" ''sum(shipping_escapes{window="24h"}) > ${toString a.EscapeFound.max.value}''
          "{{ $value }} escape(s) in the last 24 h: a revert on a default branch not reapplied since, or an open issue labelled escape. List the reverts with gh search commits --owner sammasak --committer-date \">=$(date -u -d -1day +%FT%TZ)\" Revert. Reapplying the change clears its revert (a revert made on purpose says Escape: no in its message); closing the escape issue clears it."
          { }
        )
        # per host, against its own past: a host joining (a guest) moves no other median. offset 5d: on a younger series
        # the 7-d average is still filling, so a warm-up rise, or a new host slow from the start, would fire. Slower
        # alone is no reason for a retro (a bigger change gates longer): its gates must also fail more than their average
        (alert "RetroDueGateSlower"
          "${gateMedian} > ${toString a.RetroDueGateSlower.factor.value} * avg_over_time(${gateMedian}[7d]) and on (host) shipping_gate_fail_ratio > avg_over_time(shipping_gate_fail_ratio[7d]) and ${gateMedian} offset 5d"
          "The median push gate on {{ $labels.host }} takes {{ $value | humanizeDuration }}, over ${toString a.RetroDueGateSlower.factor.value}x its own 7-d average, and its gates fail more than their 7-d average: a retro is due (https://grafana.sammasak.dev/d/shipping: where a gate's time goes, by gate step, and failed gate steps)."
          { }
        )
        # one step, or one check inside the flake check, failing on 3 heads over a full sample: one bad change on two hosts
        # makes 2, so 3 is a pattern; the flake check's own count covers only failures no inner check explains. It
        # clears newFailureHours after the unit's last failure unless its count rose since (a failure Loki received
        # late, under its old time), and fires again on the next; with no timestamp (an older collector) the count
        # alone decides. A scheduled full gate on main that started after the last failure is the pattern handled, unless
        # it deferred that check to its owner host
        (alert "RetroDueStepFailsRepeat"
          (
            let
              fails = ''max by (step, check) (shipping_gate_step_failures{window="7d"})'';
              before = ''max by (step, check) (shipping_gate_step_failures{window="7d"} offset ${toString newFailureHours}h)'';
              stale = "time() - max by (step, check) (shipping_gate_step_last_failure_timestamp_seconds) > ${
                toString (newFailureHours * 3600)
              }";
              rose = "${fails} > ${before} or ${fails} unless on (step, check) ${before}";
            in
            "${fails} >= ${toString a.RetroDueStepFailsRepeat.minFailures.value} unless on (step, check) (${stale} unless on (step, check) (${rose})) and on () ${gateRuns} >= ${toString a.RetroDueStepFailsRepeat.lastRuns.value} unless on (step, check) (max by (step, check) (shipping_gate_step_last_failure_timestamp_seconds) < on () group_left max(homelab_scheduled_gate_green_timestamp_seconds{job=\"node-exporter\"}) unless on (step, check) max by (step, check) (homelab_scheduled_gate_green_deferred{job=\"node-exporter\"}))"
          )
          "Gate step {{ $labels.step }}{{ if eq $labels.check \"step\" }} (check=\"step\": the step's own record, no inner check named on those heads){{ else if $labels.check }}, check {{ $labels.check }},{{ end }} failed on {{ $value }} heads in 7 d: a retro is due (Shipping dashboard: failed gate steps; Platform health for the runs). Rerun it alone on main: ${rerun}; a scheduled full gate on main that passes after the last failure clears this, as does ${toString newFailureHours} h with no new one."
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
