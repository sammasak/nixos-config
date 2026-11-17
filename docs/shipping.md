# Shipping metrics

Are we keeping up with the issues, how fast does work land, and how often does it fail? The Grafana dashboard
**Shipping** answers that, and Alertmanager warns when a number crosses its policy value.

## Where the numbers come from

`shipping-metrics.service` on lenovo (`modules/homelab/shipping-metrics.nix`, every 30 min) runs
`scripts/shipping-metrics.py` as the owner's user and writes `/var/lib/shipping-metrics/shipping.prom` for lenovo's
node-exporter. Its calls are read-only:

- **GitHub REST**, with the owner's `gh` login (the one the coordinator tasks use). Without a login it counts public
  repos only, and `shipping_collector_authenticated` is 0.
- **Loki**: the platform records (`scripts/platform-record.sh`) of gates, gate steps and deploys.

| Metric | What it is |
|---|---|
| `shipping_issues_open{repo,class}` | Open issues. `class` is `actionable`, `parked` (a repo in the policy's `issues.parkedRepos`) or `archived` (the repo is archived on GitHub). Actionable means neither; an issue labelled blocked or needs-decision still counts as actionable |
| `shipping_issues_open_labelled{label}` | Actionable issues carrying needs-live, needs-decision, blocked, approved or ready-for-agent |
| `shipping_issues_opened` / `_closed{window}` | Issues opened and closed in the last 24 h and 7 d, in every repo, parked and archived ones included |
| `shipping_issue_age_days{quantile}` | Age of the open actionable issues, median and p90 |
| `shipping_prs_merged`, `shipping_pr_lead_time_hours{quantile}` | PRs merged in 7 d, and their time from open to merge |
| `shipping_review_rounds`, `_first_pass_ratio`, `_prs_counted`, `_unreviewed_prs` | `Grade: N/10` comments per PR, over the last reviewed merged PRs; first pass means the first grade reached `review.passGrade` |
| `shipping_escapes{kind,window}` | Commits starting `Revert "` on default branches, and issues labelled `escape` |
| `shipping_gate_fail_ratio`, `_runs_counted`, `shipping_gate_seconds` | The last push-mode `nixos-qa` gates |
| `shipping_gate_step_failures{step}`, `shipping_deploys{result}`, `shipping_deploy_rollbacks{window}` | From the gate-step and deploy records |
| `shipping_deploy_lag_commits` / `_hours{host,node}` | Commits on main that the host's last good `just deploy` lacks, and the age of the oldest merge among them |
| `shipping_collector_success_timestamp_seconds{section}` | When each section last succeeded. A failed source writes no series, never a 0 |

Not measured:
- Hosts with no good deploy record in the last 14 days of Loki have no lag series. A `just switch` writes no record.
- Reviews posted as PR reviews rather than issue comments are not counted.

## Alerts

All are severity `warning`, team `shipping`, and each waits its `forMinutes` before firing. Alertmanager holds them
during the policy's quiet hours (`notify`, in UTC) and sends any still firing when the hours end. 19:00 to 07:30 UTC
covers 21:00 to 08:30 Stockholm in both seasons, and mutes one hour more: 20:00 to 08:30 in winter (CET), 21:00 to
09:30 in summer (CEST).

| Alert | Fires when |
|---|---|
| OpenIssuesGrowing | Actionable open issues grew on each of the last `days` days |
| PrLeadTimeHigh | The median lead time is over `medianHours` |
| ReviewFirstPassLow | The first-pass rate is under `minRatio` over a full sample of `lastVerdicts` reviewed PRs |
| GateFailRateHigh | The fail rate is over `maxRatio` over a full sample of `lastRuns` push gates |
| HostBehindMain | The host has been up and more than `maxHours` behind main for `upHours`. A sleeping host is not paged |
| DeployRolledBack | Rollbacks in the last 24 h exceed `max` |
| EscapeFound | Escapes in the last 24 h exceed `max` |
| ShippingCollectorStale | A section has not succeeded for `maxHours`, or the collector ran without the owner's gh login (`shipping_collector_authenticated` under `minAuthenticated`: public repos only), unless lenovo itself is down |

## Changing a number

Every threshold, window, `for` duration, the quiet hours and the parked repos are in
`modules/homelab/monitoring/shipping-policy.json`. Each value names the metric it
is tuned by (`tunedBy`), and the dashboard's **Policy signals** row shows the setting beside that metric's current
reading. Change a value with a PR that quotes that row: the reading, over what period, and why the new value fits it.
The rules are generated from the file (`modules/homelab/monitoring/rules/shipping.nix`). The flake check
`shipping-rules` fails if a rule, panel or `tunedBy` names a metric the collector does not emit. Its promtool tests
size their inputs from the policy, so a changed value needs no test edit.
