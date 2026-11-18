# Shipping metrics

Are we keeping up with the issues, how fast does work land, and how often does it fail? The Grafana dashboard
**Shipping** answers that, and Alertmanager warns when a number crosses its policy value.

## Where the numbers come from

`shipping-metrics.service` on lenovo (`modules/homelab/shipping-metrics.nix`, every 30 min) runs
`scripts/shipping-metrics.py` as the owner's user and writes `/var/lib/shipping-metrics/shipping.prom` for lenovo's
node-exporter. Its calls are read-only:

- **GitHub REST**, with the owner's `gh` login (the one the coordinator tasks use). Without a login it counts public
  repos only, `shipping_collector_authenticated` is 0, and PR lead time falls back to open-to-merge (one commits call
  per PR would exceed the 60 calls an hour GitHub allows without a token).
- **Loki**: the platform records (`scripts/platform-record.sh`) of gates, gate steps and deploys.

| Metric | What it is |
|---|---|
| `shipping_issues_open{repo,class}` | Open issues. `class` is `actionable`, `parked` (a repo in the policy's `issues.parkedRepos`) or `archived` (the repo is archived on GitHub). Actionable means neither; an issue labelled blocked or needs-decision still counts as actionable |
| `shipping_issues_open_labelled{label}` | Actionable issues carrying needs-live, needs-decision, blocked, approved or ready-for-agent |
| `shipping_issues_opened` / `_closed{window}` | Issues opened and closed in the last 24 h and 7 d, in every repo, parked and archived ones included |
| `shipping_issue_age_days{quantile}` | Age of the open actionable issues, median and p90 |
| `shipping_prs_merged`, `shipping_pr_lead_time_hours{quantile}` | PRs merged in 7 d, and their lead time: from the earliest author date among the PR's commits not on its base (at most GitHub's 250) to the merge, never below 0. A batch PR is opened after its gate, so its open time would measure the PR, not the work. The open time stands in for a PR whose commits cannot be read (an HTTP error, e.g. a deleted repo) or that lists none, and for every PR without a login. A merged PR's lead time is read once and kept in `/var/lib/shipping-metrics/lead-cache.json` (final answers only, pruned to the week) |
| `shipping_pr_lead_time_fallbacks{reason,window}` | Of those PRs, how many fell back to their open time: `http_error`, `no_commits`, `no_token`, `pending` (not read yet: a run reads new PRs for at most 90 s, the rest on the next runs); every reason is written, 0 included. `http_error` close to `shipping_prs_merged` means the commits API failed for every PR, so the lead time quantiles are open-to-merge and read low (Shipping dashboard, beside PRs merged) |
| `shipping_review_rounds`, `_first_pass_ratio`, `_prs_counted`, `_unreviewed_prs` | `Grade: N/10` comments per PR, over the last reviewed merged PRs; first pass means the first grade reached `review.passGrade` |
| `shipping_escapes{kind,window}` | Commits starting `Revert "` on default branches, and issues labelled `escape` |
| `shipping_gate_fail_ratio`, `_runs_counted`, `shipping_gate_seconds` | The last push-mode `nixos-qa` gates |
| `shipping_gate_step_failures{step}`, `shipping_deploys{result}`, `shipping_deploy_rollbacks{window}` | From the gate-step and deploy records |
| `shipping_deploy_lag_commits` / `_hours{host,node}` | Commits on main that the host's last good `just deploy` lacks, and the age of the oldest merge among them |
| `shipping_collector_success_timestamp_seconds{section}` | When each section last succeeded. A failed source writes no series, never a 0 |
| `shipping_collector_section_failed{section}` | 1 when the section failed this run (an error, or the 240 s run deadline), else 0; a skipped `reviews` (its `prs` failed) counts as failed |

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
| LeadTimeFallbacksHigh | More than `maxRatio` of the PRs merged in 7 d took their lead time from their open time after an HTTP error on GitHub's commits API, so the lead time reads low while the section looks fresh |
| ReviewFirstPassLow | The first-pass rate is under `minRatio` over a full sample of `lastVerdicts` reviewed PRs |
| GateFailRateHigh | The fail rate is over `maxRatio` over a full sample of `lastRuns` push gates |
| HostBehindMain | The host has been up and more than `maxHours` behind main for `upHours`. A sleeping host is not paged |
| DeployRolledBack | Rollbacks in the last 24 h exceed `max` |
| EscapeFound | Escapes in the last 24 h exceed `max` |
| ShippingCollectorStale | A section has not succeeded for `maxHours`, or failed two runs in a row, or the collector ran without the owner's gh login (`shipping_collector_authenticated` under `minAuthenticated`: public repos only), unless lenovo itself is down |

## Changing a number

Every threshold, window, `for` duration, the quiet hours and the parked repos are in
`modules/homelab/monitoring/shipping-policy.json`. Each value names the metric it
is tuned by (`tunedBy`), and the dashboard's **Policy signals** row shows the setting beside that metric's current
reading. Change a value with a PR that quotes that row: the reading, over what period, and why the new value fits it.
The rules are generated from the file (`modules/homelab/monitoring/rules/shipping.nix`). The flake check
`shipping-rules` fails if a rule, panel or `tunedBy` names a metric the collector does not emit. Its promtool tests
size their inputs from the policy, so a changed value needs no test edit.

## Navigation

How much looking around an agent does in this repo before it changes something: the Grafana dashboard
**Navigation**, per host and role, beside Shipping (nixos-config#535). No alert rules yet.

`nav-metrics.service` on every devTools host with node-exporter (lenovo, acer-swift, msi-ms7758, asus-b460m;
`modules/homelab/nav-metrics.nix`, hourly, no network) runs `scripts/nav-metrics.py` as the owner over the main-session
transcripts `~/.claude/projects/*/*.jsonl` and writes `/var/lib/nav-metrics/nav.prom`: counts only, labelled `role`
(`coordinator` when the session's name contains "coordinator", else `worker`), never a prompt, command, path or file
content. The classification is the retro's `navcost.py`, trimmed:

- **Navigation call**: Read, Grep, Glob, or a Bash command running grep/rg/find/fd/ls/tree/cat/head/tail/`sed -n`/
  `git grep|log|show` that is not a build or test and not a filter on another command's pipe.
- **Repo**: a call that names a path in a checkout (`*/nixos-config`, `~/.cache/wt/<name>`, `~/wt/<name>`), or names
  none and runs there.
- **Stretch**: the calls after a prompt from the owner or a peer session, up to the next; a repo stretch navigated
  the repo or edited a file in it. A miss: an error, an empty result, no match, no such file.

| Metric | Retro reading (12-18 Nov) | What bad looks like |
|---|---|---|
| `agent_nav_calls_before_first_edit{role,quantile}` | median 3, p90 11 | p90 above about 15, or the median rising week over week: agents cannot find the place to change |
| `agent_nav_topdirs_before_first_edit{role,quantile}` | median 1, p90 4 | p90 above about 6: one change touches many top-level areas |
| `agent_nav_repo_miss_ratio{role}` | 3.6 % | sustained above about 6 %: the paths and names agents expect are wrong or moved |
| `agent_nav_repeat_read_ratio{role}` | 56 % | creeping toward 70 % and above: files too big to hold, or context lost and fetched again |
| `agent_nav_repo_nav_calls{role}`, `agent_nav_stretches`, `agent_nav_repo_reads` | | the sample sizes behind them |
| `agent_nav_collector_success_timestamp_seconds{section}`, `agent_nav_collector_section_failed{section}` | | as the shipping collector's |

The window is the last 24 h. A role with fewer than 50 repo navigation calls in it writes `agent_nav_repo_nav_calls`
alone: a thin day is absent, not a swing (24 calls once read as a 21 % miss ratio).

It cannot see:
- subagents' navigation: the transcripts of Agent/Task calls are not read, so a delegating session reads low;
- hidden failures: a command ending `|| true`, `2>/dev/null` or `; echo rc=$?` turns a failed grep into output, so
  misses are under-counted;
- precisely what Bash does: its classification is a heuristic (build/test wins over navigation, a compound command
  counts once);
- which worktree: every checkout collapses to one repo, and a `~/.cache/wt` scratch dir counts as one;
- whether a re-read was wasteful or legitimate (the file changed after an edit or a merge);
- outcome quality: fewer lookups is better only if the change was right;
- sessions in dev-environment guests, whose transcripts stay in the guest.
