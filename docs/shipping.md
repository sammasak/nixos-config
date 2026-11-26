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
- **Loki**: the platform records (`pkgs/platform-record/platform_record.py`) of gates, gate steps and deploys.

| Metric | What it is |
|---|---|
| `shipping_issues_open{repo,class}` | Open issues. `class` is `actionable`, `parked` (a repo in the policy's `issues.parkedRepos`) or `archived` (the repo is archived on GitHub). Actionable means neither; an issue labelled blocked or needs-decision still counts as actionable |
| `shipping_issues_open_labelled{label}` | Actionable issues carrying needs-live, needs-decision, blocked, approved or ready-for-agent |
| `shipping_issues_opened` / `_closed{window}` | Issues opened and closed in the last 24 h and 7 d, in every repo, parked and archived ones included |
| `shipping_issue_age_days{quantile}` | Age of the open actionable issues, median and p90 |
| `shipping_issues_untouched{repo}` | Open actionable issues with no update for the policy's `alerts.OpenIssuesUntouched.days` |
| `shipping_prs_merged`, `shipping_pr_lead_time_hours{quantile}` | PRs merged in 7 d, and their lead time: from the earliest author date among the PR's commits not on its base (at most GitHub's 250) to the merge, never below 0. A batch PR is opened after its gate, so its open time would measure the PR, not the work. The open time stands in for a PR whose commits cannot be read (an HTTP error, e.g. a deleted repo) or that lists none, and for every PR without a login. A merged PR's lead time is read once and kept in `/var/lib/shipping-metrics/lead-cache.json` (final answers only, pruned to the week) |
| `shipping_pr_lead_time_fallbacks{reason,window}` | Of those PRs, how many fell back to their open time: `http_error`, `no_commits`, `no_token`, `pending` (not read yet: a run reads new PRs for at most 90 s, the rest on the next runs); every reason is written, 0 included. `http_error` close to `shipping_prs_merged` means the commits API failed for every PR, so the lead time quantiles are open-to-merge and read low (Shipping dashboard, beside PRs merged) |
| `shipping_review_rounds`, `_first_pass_ratio`, `_prs_counted`, `_unreviewed_prs` | `Grade: N/10` comments per PR, over the last reviewed merged PRs; first pass means the first grade reached `review.passGrade` |
| `shipping_escapes{kind,window}` | Commits starting `Revert "` on default branches, and issues labelled `escape` |
| `shipping_gate_fail_ratio{host}`, `_runs_counted{host}`, `shipping_gate_seconds{host,quantile}` | The last full `nixos-qa` gates (`mode=push`, as the pre-push hook ran them before 24 Nov, and `mode=scheduled`), by the host that ran them (the record stream's `host`: a guest is its own) |
| `shipping_gate_step_failures{step,check}` (distinct heads; the flake check by inner check, `check="step"` for a step's own record with no inner check named), `shipping_deploys{result}`, `shipping_deploy_rollbacks{window}`, `shipping_deploy_rollbacks_open{host,node}` | From the gate-step and deploy records |
| `shipping_deploy_lag_commits` / `_hours{host,node}` | Commits on main that the host's last good `just deploy` lacks, and the age of the oldest merge among them |
| `shipping_pr_phase_hours{phase,quantile}` | Where a deploy-repo (nixos-config) PR merged in 7 d spent its time, median and p90 per phase. `idle`: its last commit's committer time to the start of the first passing push gate on one of its commits after it (end minus `seconds`). It **includes any gate queue wait**: the gate record carries no queue time, so the wait cannot be split out without a new collector. `gate`: that gate's `seconds`. `gate_to_merge`: the gate's end to the merge. `merge_to_deploy`: the merge to the end of the first good deploy record after it whose sha has the merge commit (GitHub compare `ahead` or `identical`) |
| `shipping_pr_phase_prs{phase}`, `shipping_pr_gate_retries{quantile}`, `shipping_pr_phase_unmatched{reason}` | The PRs behind each phase (0 written); failed push gates on a PR's commits before its pass; PRs with `no_gate` (no passing push gate on their commits between the last commit and the merge) `not_deployed` (no good deploy has the merge yet) or `before_records` (merged before the first deploy record, 16 Nov 12:53 UTC: no deploy can be found for it, so it is left out of `merge_to_deploy` rather than timed to the first record). A PR's commits, last commit time and merge commit are kept with its lead time in `lead-cache.json` (one more call, `/pulls/{n}`); its matched deploy, and the deploys that lacked it, in `phase-cache.json`, so no merge and deploy pair is compared twice. A run spends at most 20 s on compare calls; a PR it did not reach is counted on a later run. A warm run adds about two GitHub calls per newly merged deploy-repo PR (`/pulls/{n}` and usually one compare; none when the deploy is the merge itself) and the gate records back to the oldest last commit |
| `shipping_collector_success_timestamp_seconds{section}` | When each section last succeeded. A failed source writes no series, never a 0 |
| `shipping_collector_section_failed{section}` | 1 when the section failed this run (an error, or the 240 s run deadline), else 0; a skipped `reviews` or `phases` (their `prs` failed) counts as failed |

Not measured:
- Hosts with no good deploy record in the last 14 days of Loki have no lag series. A `just switch` writes no record.
- Reviews posted as PR reviews rather than issue comments are not counted.
- PR phases see only push and scheduled `nixos-qa` gates on a PR's own commits before its merge, and `just deploy`
  records: since the push runs the fast set only (24 Nov), new PRs read `no_gate`, as the scheduled gate runs on main
  after the merge and a `just full-gate` is `mode=manual`. A PR gated another way (a green-tree shortcut, a host whose record
  never reached Loki) is `no_gate` too, and a `just switch` writes no deploy record, so its PRs match the next `just deploy`.
  PRs in other repos have no phases. A PR whose commits were not read yet (`pending`) is left out until a run reads it.
- Until the gate and deploy records cover the whole week (they begin 16 Nov), PRs merged before them read `no_gate`,
  and their `merge_to_deploy` runs to the first recorded deploy.

## Alerts

All are severity `warning`, team `shipping`, and each waits its `forMinutes` before firing. Alertmanager holds them
during the policy's quiet hours (`notify`, in UTC) and sends any still firing when the hours end. 19:00 to 07:30 UTC
covers 21:00 to 08:30 Stockholm in both seasons, and mutes one hour more: 20:00 to 08:30 in winter (CET), 21:00 to
09:30 in summer (CEST).

| Alert | Fires when |
|---|---|
| OpenIssuesUntouched | More than `max` actionable open issues have had no update (comment, label, edit) for `days` days (`shipping_issues_untouched{repo}`). Its summary carries the `gh search issues` command that lists them, oldest update first: close, park or work each. |
| PrLeadTimeHigh | The median lead time is over `medianHours` |
| LeadTimeFallbacksHigh | More than `maxRatio` of the PRs merged in 7 d took their lead time from their open time after an HTTP error on GitHub's commits API, so the lead time reads low while the section looks fresh |
| ReviewFirstPassLow | The first-pass rate is under `minRatio` over a full sample of `lastVerdicts` reviewed PRs |
| GateFailRateHigh | The fleet's fail rate (run-weighted over the hosts) is over `maxRatio` over a full sample of `lastRuns` full gates |
| ScheduledGateRed | The scheduled full gate on main failed (`homelab_scheduled_gate_red`), for `forMinutes`. It names the head, the first failed step and the last green head; see [below](#scheduledgatered) |
| ScheduledGateOverdue | No scheduled full gate has finished for `hours` while main has moved since the last one, or the scheduler has not read main for `hours`, for `forMinutes`; see [below](#scheduledgateoverdue) |
| HostBehindMain | The host has been up and more than `maxHours` behind main for `upHours` (6) in a row (`shipping_deploy_lag_hours`: the age of the oldest merge its last good `just deploy` lacks). A host off as planned is not paged, and one that wakes behind, or misses a scrape, starts its `upHours` again. Fix: `just deploy <host>` from lenovo, after `git fetch` on main |
| DeployRolledBack | Per host, rollbacks in the last 24 h with no good deploy of that host since (`shipping_deploy_rollbacks_open`) exceed `max`. Fix: what the deploy's output names, then `just deploy <host>` from lenovo; the good deploy clears it |
| EscapeFound | Escapes in the last 24 h exceed `max`: a revert on a default branch, unless a later commit of its repo reapplied it (git's `Reapply "X"`, or `Revert "Revert "X""`; an edited subject pairs with the newest earlier revert, over 30 d) or its message has an `Escape: no` line (reverted on purpose), and open issues labelled `escape` (closing one is it handled) |
| RetroDueGateSlower | Per host: its median full gate (`shipping_gate_seconds{quantile="0.5"}`) is over `factor` times its own 7-d average and its gate fail ratio is above its own 7-d average, for `forMinutes`, once its series is at least 5 d old (`offset 5d`): slower alone is no retro, a bigger change gates longer, and a new host (a guest) slow from the start fires nothing and moves no other host's median |
| RetroDueStepFailsRepeat | One full-gate step, or one check inside the flake check, failed on at least `minFailures` distinct heads in 7 d (`shipping_gate_step_failures`) over a full sample of `lastRuns` full gates, for `forMinutes`. One bad change that fails on a second host makes 2, so 3 is a pattern; it names the step and the command that reruns it alone (as ScheduledGateRed, [below](#scheduledgatered)). It clears when a scheduled full gate on main that started after that unit's last failure passes (`homelab_scheduled_gate_green_timestamp_seconds`), unless that gate deferred the check to its owner host (`homelab_scheduled_gate_green_deferred`), and `newFailureHours` after that unit's last failure (`shipping_gate_step_last_failure_timestamp_seconds`) unless its count rose since (a failure Loki received late), so a handled pattern stops paging within a day instead of a week, and fires again on its next failure while the count holds; the window outlasts the quiet hours (asserted), so a night's failure still pages in the morning |
| ShippingCollectorStale | A section has not succeeded for `maxHours`, or failed two runs in a row, or the collector ran without the owner's gh login (`shipping_collector_authenticated` under `minAuthenticated`: public repos only), unless lenovo itself is down |

## The scheduled full gate

A push runs the fast set only (CLAUDE.md, the pre-push hook) and owes the full gate. `scheduled-gate.timer` on
acer-swift (`modules/homelab/scheduled-gate.nix`, at 03:20, 11:20 and 19:20) fetches origin/main into
`/var/lib/scheduled-gate/repo` and, when main has moved since the last finished run, runs `devenv tasks run nixos:qa`
in a worktree just added at that commit, as the owner. nixos:qa waits for the heavy-work lock itself and records the
gate (`gate=nixos-qa mode=scheduled`) and its steps in Loki, as a push's gate did; its step times are in
`/var/lib/scheduled-gate/nixos-qa-times`. `pkgs/scheduled-gate` keeps the last finished run in `state.json` there and
writes `metrics/scheduled-gate.prom` (`homelab_scheduled_gate_*`) for acer's node-exporter. A red head is run once
more on the next timer, so a failure outside the tree clears itself; red again, it waits for the next commit to main. To gate a branch now, before merging a risky change:
`just full-gate [REF]`.

### ScheduledGateRed

Fires: the last finished scheduled gate failed. The summary names the head, the first failed step (`step`; for the
flake check, the check inside it, `check`, whether it failed to build, evaluate or dry-run) and `green..head`, the
commits since the last green scheduled run; `unrecorded` means nixos:qa failed before its first step record (devenv's
evaluation, the devenv-fresh guard).
First: rerun that step alone in a checkout of the head, with the command the summary names: `nix build -L .#<check>`
for a flake check's check, `NIXOS_STEP=<step> devenv tasks run nixos:step` for any other step, `devenv tasks run
nixos:qa` for `unrecorded`. RetroDueStepFailsRepeat names the same command. On acer, `journalctl -u scheduled-gate -n
200` has the run's log, and `git log --oneline <green>..<head>` lists the suspects. The alert clears when a later
scheduled run on main passes, the retry of the same head included.
Do not: edit `state.json` to clear it; a fix merged to main is what clears it.

### ScheduledGateOverdue

Fires: main has moved and no scheduled gate has finished for `hours`, or the scheduler has not read main for that
long (`homelab_scheduled_gate_checked_timestamp_seconds`). Usually a long wait for the heavy-work lock, a run killed
at its 8 h `TimeoutStartSec`, or a failed fetch.
First: on acer, `systemctl status scheduled-gate.timer scheduled-gate`, `just heavy-busy` for the lock's holder, and
`journalctl -u scheduled-gate -n 50`. A failed unit also shows as NodeSystemdUnitFailed. The textfile is absent until
the unit's first run, and then this alert cannot fire: after a deploy of acer, check that the series exists.

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
| `agent_nav_collector_skipped{worker,reason}` (guests only) | | above 0: a guest's transcripts left out, see below |

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
- outcome quality: fewer lookups is better only if the change was right.

**Guests.** On a host that declares dev environments (acer-swift: its pool slots), each declared instance gets its own
`nav-metrics-guest@<name>.service` and timer (hourly at :38, same module): the same script with `--worker <name>`, over
`<stateDir>/<name>/home/.claude/projects/*/*.jsonl` with the guest's home path for `~`, writing
`/var/lib/nav-metrics-guests/nav-guest-<name>.prom` in its own textfile directory: the same series, each with
`worker=<name>`, the collector's own series included, so no two files share a series. One process, file and MemoryMax per
guest: a guest whose transcripts kill or stall its run stales its own series alone. A removed instance's file is
deleted two days after its last write (tmpfiles). The name comes from the host's declaration, never from a transcript. The dashboard's host panels select `worker=""`; its Guests
row selects `worker!=""`.

The guest controls everything in its home, so the reader:
- runs as root with `CAP_DAC_READ_SEARCH` as its only capability (the instance dirs and homes are 0700), and is read-only
  everywhere but its own directory, with no network, no devices and MemoryMax 64M. Root, not a dynamic user: node-exporter
  cannot read a dynamic user's state dir under the 0700 `/var/lib/private`;
- opens each directory from its parent's fd without following a link, and opens a transcript only if it is a regular
  file, non-blocking so a FIFO cannot hold the open. A link, FIFO or other special file anywhere on the path is refused
  and counted (`reason="refused"`), and nothing behind it is read;
- reads at most 256 transcripts per guest and run (`too_many`) and none over 256 MiB (`too_large`), and skips any line
  over 2 MiB. The owner's busiest day had 107 transcripts, the largest 119 MB and the longest line 660 KB;
- abandons a transcript whose per-session state passes 10,000 entries (distinct repo files read, calls awaiting a
  result, a stretch's top-level directories, the run's stretches) or that holds a Bash command over 64 KiB, and keeps
  none of its counts (`too_much_state`). Bytes alone do not bound memory: 400,000 distinct reads in a 108 MB transcript
  took 167 MB. The owner's 325 transcripts peak at 159 files read, 3 pending, 12 directories, 180 stretches in a
  session (530 in all) and a 23 KB command, so the owner's run has the same caps and they never trigger;
- exports counts only. A session's name, cwd, prompts and paths decide its role and what counts as the repo, but none
  of them reaches a label.

The guest reader also cannot see:
- anything the guest chooses to hide or fake: it can delete, rewrite or invent its own transcripts, so its numbers are
  self-reported. It cannot change another worker's series or the host's;
- a home that was reset or retired: its transcripts go to `.trash` with it, and the next run reads the new home alone;
- what lies past the caps: those transcripts are counted but not read.
