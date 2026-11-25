# Alert runbooks

One section per alert in `modules/homelab/monitoring/rules/homelab.yaml`, `modules/homelab/monitoring/rules/shunt.yaml`,
`modules/homelab/monitoring/rules/exec-pool.yaml`, `modules/homelab/monitoring/rules/alert-investigations.yaml`,
`modules/homelab/monitoring/rules/llm-gateway.yaml` and Loki's ruler
rules, `modules/homelab/monitoring/loki-rules/fake/homelab.yaml`; each alert's `runbook_url` points at its heading here.
The shipping alerts point at [shipping.md](shipping.md#alerts). The kube-prometheus-stack rules (`general.yaml`,
`node-exporter.yaml`, `alertmanager.yaml`, `prometheus.yaml` there) keep upstream's runbook,
`https://runbooks.prometheus-operator.dev/runbooks/<area>/<alert in lower case>`, and their `query` is their `expr`;
TargetDown, the one of them that fires with every outage, has its own section here.

Every alert in a rule file black-pi's Prometheus loads, and every Loki-ruler alert, carries the same annotations, held
by the `monitoring-alert-annotations` check (`flake-modules/monitoring-check.nix`, `scripts/check-alert-annotations.py`):

| annotation | holds |
|---|---|
| `summary` | one line: the symptom and the component |
| `description` | the observed condition, its threshold and duration, the affected host or service, the first safe step |
| `query` | the first diagnostic PromQL, runnable as is in Prometheus on black-pi (`{{ $labels.* }}` are filled in by Prometheus); the `grafana-dashboards` check parses it and holds its metric names and jobs. A Loki-ruler alert's is LogQL, for Grafana's Explore on the Loki data source, and that check does not read it |
| `runbook_url` | a heading in a tracked doc of this repo, on `main`; for a kube-prometheus-stack rule, upstream's page for that alert |

The ntfy page (Alertmanager's webhook payload, `modules/homelab/monitoring/alertmanager.nix`) carries `summary`,
`description` and `Query: <query>`, and a tap opens `runbook_url`; all four also show in Prometheus's alert view. Run a PromQL query at `http://192.168.10.137:9090/graph`.

## HostExpectedOff

Fires: a sleeping host's node-exporter does not answer inside its planned power-off. Null route, never notifies; it
feeds the inhibit rules in `modules/homelab/monitoring/alertmanager.nix`. TargetDown leaves out the targets of such a
host through the same record, `homelab:node:off_as_planned`, so a planned power-off does not count as a target down.
First: nothing to do. If the host should be on, check its power window in `modules/core/fleet.nix`.

## TargetDown

Fires: over 10 % of a job's scrape targets have not answered black-pi's Prometheus for 10 minutes, leaving out the
targets of a host off as planned (`homelab:node:off_as_planned`). One page per job; a host down outside its plan also
fires NodeChronicNotReady, which names it.
First: the `query` lists the down targets; `http://192.168.10.137:9090/targets?search=<job>` shows each one's scrape
error. A refused connection is the exporter's unit on that host (`systemctl status` it there), a timeout the host or
the LAN.

## NodeChronicNotReady

Fires: `up{job="node-exporter"}` is 0 for 15 minutes outside the host's planned power-off.
First: `ping` the host and `ssh` to it; on it, `systemctl status prometheus-node-exporter`.
Do not: mark the host `sleeps` to silence it.

## GpuTelemetryDown

Fires: the host's node-exporter answers but its nvidia-gpu exporter has not for 5 minutes.
First: on the host, `systemctl status prometheus-nvidia-gpu-exporter` and `nvidia-smi`; `journalctl -k | grep NVRM`.

## NodeOOMKill

Fires: `node_vmstat_oom_kill` increased in the last 15 minutes, for 2 minutes. Inhibited while UnitOOMKilled fires
for the same host, which names the unit; so it pages alone only for a kill whose journal line did not reach Loki.
First: on the host, `journalctl -k --since -1h | grep -i 'killed process'` names the process and its cgroup.
Do not: raise a `MemoryMax` before the journal shows which unit hit it.

## UnitOOMKilled

Fires: systemd logged "A process of this unit has been killed by the OOM killer" for a system unit in the last 15
minutes (Loki's ruler on black-pi; `run-*`, `session-*` and `systemd-coredump@*` fold as the journal collector folds them). It
names the unit that NodeOOMKill only counts, and inhibits NodeOOMKill on the same host, so one kill pages once. Its `query` is LogQL, for Grafana's Explore.
Not matched: kills by systemd-oomd, and user units (their journal is not shipped).
First: on the host, `journalctl -u <unit> -b` and `systemctl show <unit> -p MemoryMax -p MemoryPeak`.
Do not: raise the unit's `MemoryMax` before its journal shows what grew.

## NodeSystemdUnitFailed

Fires: a service, socket, timer, target or path unit is in the failed state for 15 minutes.
First: on the host, `systemctl status <unit>` and `journalctl -u <unit> -b`. `systemctl reset-failed <unit>` once
the cause is fixed.

## NodeTemperatureHigh

Fires: black-pi's `cpu-thermal` zone reads 85 °C or more for 15 minutes.
First: the Hosts dashboard's temperature panel; check the Pi's fan and airflow.

## GpuThermalThrottling

Fires: the GPU reports hardware thermal slowdown for 10 minutes.
First: the GPU dashboard's temperature, fan and power panels; `nvidia-smi -q -d TEMPERATURE,PERFORMANCE` on the host.

## DnsDown

Fires: `homelab_dns_up` is 0 for 5 minutes: AdGuard on the DNS host does not answer its control API.
First: on the DNS host, `systemctl status adguardhome` and `journalctl -u adguardhome -b`.

## DnsStatsStale

Fires: `adguard.prom` has not been rewritten for over 5 minutes, for 10 minutes, so DnsDown is blind.
First: on the DNS host, `systemctl list-timers adguard-textfile` and `journalctl -u adguard-textfile`.

## RootFilesystemLow

Fires: under 3 GiB free on `/` for 15 minutes.
First: on the host, `df -h /` and `du -xsh /var/lib/* /nix/store 2>/dev/null | sort -h | tail`. On black-pi,
Prometheus is capped at 1500MB; check `/var/lib/loki`.
Do not: delete Loki or Prometheus data by hand; `nix-collect-garbage` only with the owner.

## LokiIngesterDown

Fires: Loki on black-pi exports no ingester metric, or its scrape target is down, for 5 minutes. New logs are not
persisted.
First: on black-pi, `systemctl status loki` and `journalctl -u loki -b`.

## JournalEntriesDropped

Fires: `homelab_journal_writer_dropped_entries_total` rose in the last 15 minutes on a host whose node-exporter
answers, for 5 minutes. Those journal lines are not in Loki. `reason` is Alloy's own (`rate_limited`,
`queue_is_full`, `ingester_error`, `line_too_long`, `stream_limited`, else `other`).
First: on the host, `journalctl -u alloy --since -30m`; on black-pi, `journalctl -u loki --since -30m` for the
rejection's side of a `rate_limited` or `ingester_error`.
Do not: raise Loki's limits before the journal shows which stream hit them.

## JournalMetricsStale

Fires: the host's last journal-metrics collection failed (`homelab_journal_metrics_collection_success` 0), is over
180 seconds old, or the host is up with no `journal.prom` at all, for 10 minutes, so JournalEntriesDropped is blind
there. A host that is off has no series and does not fire.
First: on the host, `systemctl status journal-metrics.timer journal-metrics alloy` and `journalctl -u journal-metrics -n 20`.

## GuestRecordsNotShipping

Fires: a worker's guest has platform record lines waiting (`homelab_guest_records_waiting_lines` above 0) and
`dev-env-records` has not got through that worker for over 30 minutes
(`homelab_guest_records_shipped_timestamp_seconds`, 0 if it never has), for 10 minutes. The timer runs every 5
minutes and a run that ships its 500 lines counts, so a large backlog draining does not fire. Those lines are in the
guest's spool, not in Loki, so that worker's gate and coverage records are missing there. The textfile
is `/run/dev-env-records-metrics/guest-records.prom` on the host; a worker refused for a link or FIFO on its spool
has no series and fails the unit instead (NodeSystemdUnitFailed). A run killed at its 2 minute timeout writes
nothing: the last file stays, and its timestamp keeps ageing.
First: on the host, `journalctl -u dev-env-records -n 20`: `Loki unreachable` or `Loki answered 5xx` is Loki's
side (black-pi, `systemctl status loki`); a timeout is a slow run.
Do not: delete the worker's spool or its progress under `/var/lib/private/dev-env-records`; the next run that
reaches Loki ships what waits.

## BackupStale

Fires: `time() - homelab_backup_last_success_timestamp_seconds` is over 36 hours for 10 minutes. Every job is a daily
timer, so one run has failed, been skipped or not run. The timestamp exists only after a recorded success, and
`backup.prom` is on tmpfs: a backup with no record is BackupNeverRecorded, a stale or missing collector
BackupCollectorStale.
First: on the host, `systemctl list-timers <backup>`, `systemctl status <backup>` and `journalctl -u <backup> -n 50`.
Do not: start a production backup by hand only to clear the alert; let the timer run once the cause is fixed.

## BackupNeverRecorded

Fires: `homelab_backup_metadata_available` is 0 for 36 hours: the collector finds no valid `success.json` for that
backup. The job has not completed since it was instrumented, or its post-success record step (an `ExecStartPost` whose
failure systemd ignores) did not write.
First: on the host, `journalctl -u <backup> -n 50` for the run and the `backup-metrics record` line after it;
`ls -l /var/lib/backup-metrics/<backup>/`.
Do not: write `success.json` by hand.

## BackupCollectorStale

Fires: the backup-metrics collector's last completed scan is over 900 seconds old, or acer or lenovo is up with no
`backup.prom` at all (it is on tmpfs, so a collector that never ran since boot leaves nothing), for 15 minutes.
First: on the host, `systemctl status backup-metrics.timer backup-metrics` and `journalctl -u backup-metrics -n 20`.

### Drill: a blind collector

A live fire and resolve of a monitoring-blindness alert through the real rule, Alertmanager and ntfy, with nothing
real made blind: black-pi runs no backup, so a synthetic collector series there fires BackupCollectorStale for
`node="black-pi"` alone, and no other rule reads that metric. The `backup.yaml` rule test runs these steps in promtool;
the `alert-fire-resolve` VM check proves the page's format. Run it in the daytime and say so first: it pages once.

1. As root on black-pi, write the series an hour stale (node-exporter reads only `*.prom`):
   `ssh -t black-pi 'printf "homelab_backup_collector_last_success_timestamp_seconds %d\n" $(( $(date +%s) - 3600 )) | sudo tee /run/node-exporter-textfile/synthetic.tmp >/dev/null && sudo mv /run/node-exporter-textfile/synthetic.tmp /run/node-exporter-textfile/synthetic.prom'`
2. Within a minute, `time() - homelab_backup_collector_last_success_timestamp_seconds{node="black-pi"}` reads about
   3600 at `http://192.168.10.137:9090/graph`, and `http://192.168.10.137:9090/alerts` shows BackupCollectorStale
   pending for black-pi.
3. After 15 minutes it fires: `http://192.168.10.137:9093` lists one BackupCollectorStale, `node="black-pi"`,
   `severity="warning"`, `team="homelab"`, and within the 30 s group wait ntfy's `homelab-alerts` gets one
   `[WARNING]` page at priority 3: the summary "The backup-metrics collector on black-pi is stale or missing", its
   description, `Query: time() - homelab_backup_collector_last_success_timestamp_seconds{job="node-exporter",node="black-pi"}`
   and a tap to this runbook. Note both times.
4. Remove it: `ssh -t black-pi sudo rm /run/node-exporter-textfile/synthetic.prom`. At the next scrape the series is
   stale, the alert resolves and ntfy gets its resolved message at priority 1 within one group interval (5 minutes).
   Note the time; no second firing page may arrive.

If step 4 is missed the page repeats every 12 hours until black-pi reboots (`/run` is tmpfs). The edge dashboard's
collector-age panel shows a black-pi line for the drill.

## OtlpWritesRejected

Fires: acer's alloy-otlp receiver (`otelcol.receiver.otlp.native`, behind `otlp.sammasak.dev`) answered OTLP POSTs
with a 4xx or 5xx in each 5-minute window for 10 minutes, per status. The writes are lost though every scrape is green.
The counter is otelhttp's `http.server.request.duration_seconds_count`, as Prometheus stores it (Alloy is scraped with
`allow-utf-8`, so names and labels keep their dots: `"http.response.status_code"`, `"http.request.method"`). The
receiver's own `otelcol_receiver_refused_*`/`_failed_*` counters stay 0 on a 401 or an oversized 400. The sender is not
in the series.
Read the status of a POST: 401 is a bearer token that does not match acer's (a relay's `native_otlp_auth`), 400 an
oversized (over 1 MiB) or malformed body, 429 or 503 Alloy's memory limiter or full sending queue. The blackbox probe's
GET of `/v1/logs` carries no token and is answered 401 about twice a minute all day: expected, and excluded by the
`"http.request.method"="POST"` matcher; the token reading applies to POSTs only.
Blind spot: a host relay (`native-otel-relay`) refusing a post itself (413 over `client_max_body_size 1m`, 429 from
`limit_req`) never reaches acer and has no metric; only that host's nginx line in its journal shows it.
First: on acer, `journalctl -u alloy-otlp --since -30m`; for a 401 or 413, on the sending hosts,
`journalctl -u native-otel-relay --since -30m`.
Do not: raise `max_request_body_size` or the relay's body limit before the journal names the sender.

## ClaudeCompactionLoop

Fires: Claude Code on one host or worker auto-compacted more than 5 times in the last hour, read from
`host_worker:claude_code_auto_compactions:count1m`, which Loki's ruler records from the sanitized compaction events
(`modules/homelab/monitoring/loki-rules/fake/homelab.yaml`). An empty `worker` is a session on the host itself. One session compacting again and
again is a loop: its context refills right after each compaction and the goal it started with gets lost. It resolves
once the hour holds 5 or fewer. The count is a lower bound, so a real loop may fire a few minutes late.
First: in Grafana's Explore on Loki, the events of that worker by session (ids are line fields, never labels):
`sum by (attributes_session_id) (count_over_time({observer="harness", service_name="claude-code", event_name="compaction", host_name="<host>"} | json | attributes_trigger="auto" | attributes_worker="<worker>" [1h]))`.
For an empty worker, filter `attributes_worker=""`. One session with most of them is the loop: stop it there. Many sessions each compacting a few times is load, not a
loop.
Rollback: for a worker with `sam.claude.autoCompactWindow` set, remove it from its host's guest module (an
approved deploy); a session keeps the window it started with until restarted.
Do not: raise the threshold before the events show which session it was.

## EdgeSocketDown

Fires: nothing listens on Caddy's upstream socket on acer, or the edge check stopped writing, for 2 minutes. Signed-in
users get a 502.
First: on acer, `systemctl status open-webui-edge-check.timer`; then `systemctl restart open-webui-proxy-rebind`
(it stops the proxy first, or the socket refuses to start).

## AppDown

Fires: black-pi's HTTPS probe of a public name through Caddy fails for 5 minutes.
First: `http://192.168.10.137:9090/targets?search=blackbox` for the probe's error; `curl -sv https://<name>` from the
LAN; on acer, `journalctl -u caddy --since -10m`.

## CertificateExpiringSoon

Fires: the certificate a public name serves expires in under 14 days, for an hour.
First: on acer, `journalctl -u caddy | grep -i acme` for the renewal's error.

## ShuntCollectorStale

Fires: on a host that enables `homelab.shuntMetrics` (lenovo, acer), `shunt-metrics.service` has not read the hook
log successfully for over 45 minutes, its runs kept failing for 20 minutes, or its unit exists but has never written
`/var/lib/shunt-metrics/shunt.prom`; with a worker label, the same for that guest's
`shunt-metrics-guest-<worker>.service`. A sleeping or disabled host never fires: the alert reads the collector's own
series and unit. The Shunt panels on Agent harnesses and ShuntDelegationFailing are blind while it fires.
First: on the host, `systemctl status shunt-metrics.timer shunt-metrics.service` and `journalctl -u shunt-metrics.service`
(for a worker, `shunt-metrics-guest-<worker>`);
the script names a failed scan's exception type there. `ls -l ~/.local/state/claude-hooks/` shows whether the hook log exists.
Do not: delete the textfile to silence it; a missing file fires as well.
Rollback: `homelab.shuntMetrics.enable = false` in the host's configuration and deploy; Shunt itself keeps working.

## ExecPoolQueueDown

Fires: on a host that runs the execution pool queue (`modules/homelab/exec-pool.nix`, acer), `exec-pool-metrics` has
written `exec_pool_queue_up 0` for 10 minutes (PostgreSQL or the `exec_pool` database did not answer), or has not
rewritten `/var/lib/exec-pool-metrics/exec-pool.prom` for over 10 minutes. An empty queue is up 1 with zero counts and
never fires; a sleeping host never does. A failing collector unit also fires SystemdUnitFailed.
First: on the host, `systemctl status postgresql.service exec-pool-migrate.service exec-pool-metrics.timer
exec-pool-metrics.service` and `journalctl -u exec-pool-metrics.service -u exec-pool-migrate.service`; the CLI names the
error there (exit 75: the database is unavailable). Authentik's database is on the same server (`modules/homelab/postgresql.nix`), so its health is the same check.
Do not: delete the textfile or write `exec_pool_queue_up 1` by hand; nothing dispatches from the queue yet, so there
is no task to rescue.
Rollback: drop the `exec-pool.nix` import from acer's configuration and deploy; the `exec_pool` database stays until
dropped by hand.

## ExecPoolLeaseOverdue

Fires: for a slot host (`host`, though acer's queue renders it), `exec_pool_lease_overdue` has been above zero for 10 minutes: an attempt is leased,
running or checkpointing past its lease deadline and no `reconcile` has expired it. Its runner died or stopped
heartbeating, or no runner reconciles at all yet (nothing runs `reconcile` on a timer on main), so the task neither
runs nor goes back to the queue; its slot counts as busy.
First: on the host, the overdue attempts:
`sudo -u exec_pool psql -h /run/postgresql exec_pool -c "SELECT id, status, lease_epoch, slot, lease_deadline FROM
attempts WHERE status IN ('leased', 'running', 'checkpointing') AND lease_deadline <= now()"`; where a runner is
deployed (#652), `journalctl -u 'exec-pool-runner*'` holds its last `state_change` line and why it stopped. Once no
runner is working that attempt, `sudo -u exec_pool env EXEC_POOL_DB='host=/run/postgresql dbname=exec_pool user=exec_pool' exec-pool-queue reconcile`: a lease that never started goes back to queued, a
started one to `needs_review` (ExecPoolNeedsReview).
Do not: edit `lease_deadline` or `status` in the database; the fence refuses a stale writer only if the epochs move.
Rollback: stop the runner; the queue keeps the attempt for the reconcile.

## ExecPoolNeedsReview

Fires: an attempt (a session's included) last run on `host` has been in `needs_review` for 30 minutes in the pool
host's queue: it started and then lost its lease, or settled there, so whether its effects (a push, a PR, a comment)
happened is unknown. Nothing resolves it automatically.
First: its id and epoch: `sudo -u exec_pool psql -h /run/postgresql exec_pool -c "SELECT id, task_id, lease_epoch,
slot FROM attempts WHERE status = 'needs_review'"` (where a runner is deployed, its `state_change` lines in
`journalctl -u 'exec-pool-runner*'` say how it got there). Check its effects in the task's repository, then
`sudo -u exec_pool env EXEC_POOL_DB='host=/run/postgresql dbname=exec_pool user=exec_pool' exec-pool-queue resolve --attempt ID --epoch N --to succeeded|failed|queued` (queued only if the effects did not
happen). A session goes on with `exec-pool send ID --prompt TEXT` once its last turn's effects are checked.
Do not: resolve to queued without checking the effects; a replay can push or comment twice.
Rollback: none; the alert clears when no attempt is left in needs_review.

## ExecPoolSlotQuarantined

Fires: a slot on `host` has been in the pool host's `quarantined_slots` for 5 minutes (acer's queue holds acer's and
msi's slots; `host` is the slot's, not the scrape's `node`): its runner's `dev-env-reset@<slot>` refused three times (an agent running in the guest, or unpushed work
outside `~/attempts`), so the runner wrote `/var/lib/exec-pool-runner/<slot>.quarantined`, cleared the reset unit's
failed state, and keeps running without claiming for that slot. Its other slots and the queue are unaffected.
First: which slot and why: `sudo -u exec_pool psql -h /run/postgresql exec_pool -c "SELECT host, slot, reason, since
FROM quarantined_slots"`; on that host, `journalctl -u exec-pool-runner-<slot> -u dev-env-reset@<slot>` has the
refusal. Stop the agent or push (or deliberately discard) the work in the guest, then on that host
`sudo rm /var/lib/exec-pool-runner/<slot>.quarantined`: the runner's next pass resets the slot and deletes the row, and
the alert clears.
A slot quarantined for a session turn's work left in its dock (the reason names `dock-busy`, and why its push did not
land): once nothing of the turn runs, push that work from `<stateDir>/.sessions/dock/<slot>/cur/work` to the task's
branch or snapshot ref (or archive it), then remove `/var/lib/exec-pool-exec/<slot>/dock-busy` and the quarantine
marker; the reason names both paths.
Do not: delete the row alone while the slot exists; the runner rewrites it while its marker stands. A slot no longer
declared (fewer slots, a renamed host) has no runner to clear it: delete its row with
`DELETE FROM quarantined_slots WHERE host = '<host>' AND slot = '<slot>'` as `exec_pool`.
Rollback: none; a slot that resets clears itself.

## ExecPoolQueuedWithIdleSlot

Fires: the oldest queued attempt whose agent an idle slot offers (`exec_pool_queued_claimable_oldest_seconds`: a slot
that claimed in the last two minutes, holds no lease and is not quarantined) has waited over 15 minutes, for 5 minutes.
An idle slot claims every ten seconds, so its claim keeps passing this task over: capabilities or a resource class no
idle slot has, a session pinned to the host it last ran on (a turn that never parked), or a claim that errors.
First: `exec-pool list` and `exec-pool status ID` for the task; on the idle slots' hosts,
`journalctl -u 'exec-pool-runner-*' --since -30min` for claim errors; `exec_pool_slots{state="idle"}` by `host` says
which hosts are idle. A session pinned to a sleeping or drained host waits for it by design: wake the host or cancel.
Do not: lower the task's requirements in the database; resubmit it instead.
Rollback: none; the alert clears once the task is claimed or cancelled.

## ExecPoolParkPushFailing

Fires: at least two tries to push a parked session turn's work from `node` failed within an hour, for 5 minutes
(`exec_pool_park_push_failures_total`, each slot's exec helper's textfile). The helper keeps trying for 30 minutes; a
park that never got its push through goes to `needs_review`, and its uncommitted work stays in the slot's dock
(`/var/lib/workers/.sessions/dock/<slot>/cur/work`), marked, with the slot quarantined.
First: on `node`, `journalctl -u 'exec-pool-exec@*' --since -1h | grep -i 'park push'` for the git error; check the
GitHub sidecar (`dev-env-egress` on acer, its token) and that the repository is still listed for the slots.
Do not: `exec-pool send` the session before its dock's work is pushed: its next turn clones the remote on any host and
would not see it.
Rollback: none; push the dock's work by hand (or archive it), remove the dock's `dock-busy` mark and the slot's
quarantine marker, then send the session.

## ExecPoolPrepareFailing

Fires: three or more runs on `node` failed before their agent started at the same `step` within an hour, for 5
minutes (`exec_pool_prepare_failures_total{step}`: a prepare step's unit, such as `exec-pool-clone` or
`exec-pool-checkout`, or `admit`, `attach`, `manifest`, `turn` outside one). Each requeues its task and spends a try,
so repeated ones end as `attempts_exhausted` with nothing run. The first failure of a step after a host boots creates
the series, so it counts from the second.
First: `exec-pool result ID` for one of them: its output reads `prepare failed at <step> (exit N):` and the step's
stderr tail (git exit 128 is usually the repository URL, the credential proxy or a missing rev). On `node`,
`journalctl -u 'exec-pool-runner-*'` has each run's `failed_step` and `stderr_tail`.
Do not: raise the task's max attempts to get past it; the cause repeats.
Rollback: none; the increase ages out of the hour once prepares succeed.

## ExecPoolSessionStalled

Fires: a session last run on `host` has waited for 5 minutes after a turn that parked as `reason` (`turn_error` or
`turn_timeout`) with no automatic continue left and nothing in its inbox (`exec_pool_sessions_stalled`, the queue's
textfile on acer). A turn that ends in an error gets up to three continues in a row, due 10, 30 and 90 minutes after
it (a rate limit is not met again at once); one stopped at its time limit up to two at once, the third waits. Each
continue is a new turn told what happened, never a replay of its last action. Errors and timeouts mixed share one
run, at most four turns. A message starts the count again.
First: `exec-pool list` names it (parked `turn_error` or `turn_timeout`); `exec-pool status ID` has its turns and
`exec-pool logs ID` (`--turn N` for an older one) what the agent printed: a rate limit or expired login, a broken
slot (`exec-pool result ID`), or a task too big for one turn. Fix that, then
`exec-pool send ID --prompt TEXT` saying what happened and what to do next.
Do not: send it "continue" while the cause stands; it fails the same way and stalls again after three more turns.
Rollback: none; the alert clears when the session is woken or cancelled (`exec-pool cancel ID`).

## AlertInvestigationFailed

Fires: on the host that runs `alert-investigations` (`modules/homelab/alert-investigations.nix`, lenovo, for the
names in `homelab.alertInvestigations.alerts`), an investigation it started in the last 6 h failed, or for 15 minutes
it has not read Alertmanager. An investigation is one read-only incident-investigator pool session per firing that
lasted 15 minutes, its report a comment on the issue titled `Alert: <name>` (label `alert-investigation`); it fails
when `exec-pool start` refuses it, the session ends `failed`, `cancelled` or `needs_review`, its first turn ends
without a report, the session pushed `pool/<task id>` (it is read-only), no report came within 3 h (it is cancelled),
or the report could not be posted. The issue is public: a posted text has secret-shaped values
(tokens, keys, `password=`) replaced by `[redacted]`, and the session is told to quote none. With `alertname`, an investigation of that alert failed; without it, the trigger
is blind.
First: on lenovo, `journalctl -u alert-investigations.service` names the session and the reason;
`homelab_alert_investigation_failures_total` counts them by reason. The issue holds the session id: `exec-pool result
ID` and `exec-pool logs ID` show what it did. A pushed branch is left for the owner to read and delete. Without
`alertname`, `curl -sf http://192.168.10.137:9093/-/ready` from lenovo.
Do not: delete `/var/lib/alert-investigations/state.json` to clear it; the counters and the per-name issue numbers
live there, and every firing still active would be investigated again.
Rollback: `homelab.alertInvestigations.alerts = [ ];` on lenovo and deploy; started sessions stay in the pool.

## AlertInvestigationsStale

Fires: `alert-investigations` on the host has not rewritten `/var/lib/alert-investigations/alert-investigations.prom`
for over 20 minutes: its timer (every 2 minutes) stopped or every run hangs, so nothing is investigated and
AlertInvestigationFailed cannot fire.
First: `systemctl status alert-investigations.timer alert-investigations.service` and `journalctl -u
alert-investigations.service` there. A run waits up to 120 s per command (ssh to the pool host, gh).
Do not: write the textfile by hand.
Rollback: as AlertInvestigationFailed's.

## ExecPoolSessionsLarge

Fires: on a pool host (acer, msi), the slots' session docks (`/var/lib/workers/.sessions/dock/<slot>/cur`, one session
turn's checkout and home each, made afresh every turn) have held over 70% of the workers' state filesystem for 30
minutes. `dev-env-sessions-metrics` (`modules/workers/core.nix`) writes the bytes every 15 minutes, with no ids. A dock
is removed at its park once the work is on the remote; one kept after a failed park push stays (ExecPoolParkPushFailing).
First: `sudo du -sh /var/lib/workers/.sessions/dock/*` names the largest; a running turn's build outputs shrink at its
park.
Do not: delete a dock whose slot has `dock-busy` beside its run directories (`/var/lib/exec-pool-exec/<slot>/`): it
holds a running turn or unpushed work.
Rollback: none; the alert clears when the docks fall under 70%.

## ExecPoolCompactionWindowCostlier

Fires: over the last day, the Claude turns on a pool host's slots with a declared `sam.claude.autoCompactWindow`
(`variant`, the window in tokens) cost over 1.5 times per turn what the same host's default slots cost, with Shunt off
on both sides and at least 10 turns on each, for an hour. Read from the `host_variant:exec_pool_session_*:increase1d`
records (`modules/homelab/monitoring/rules/exec-pool.yaml`): the queue's usage by the arm (window and Shunt) each slot's
runner records with its turns (`EXEC_POOL_ARM`, `modules/homelab/exec-pool-runner.nix`). This is #626's live
comparison judging the window worse.
First: the "Compaction window on versus off" table in the Agent harnesses dashboard (Sessions row): tokens per turn and
per session, turns per session and auto compactions per session per variant. One long session on the on side can carry a
day; `exec-pool list` names the sessions.
Rollback: set that slot's `sam.claude.autoCompactWindow` back to null in its host's guest module
(`hosts/acer-swift/configuration.nix` for acer's `pool2`) and deploy the host; the slot's next turn starts with Claude's
default. The alert clears when the day's ratio falls under 1.5.

## ShuntDelegationFailing

Fires: over a quarter of the bulk-read delegations in the collector's 24 h window failed with auth, rate_limited,
model_unavailable, timeout or error, with at least 10 attempts, for 30 minutes. Refusals by policy (private, secret,
sensitive, invalid) count as attempts, not failures. Sessions still get the fallback: they read the file themselves,
so the cost is context, not correctness. The window is 24 h, so it resolves only once the failures age out of it or
the share drops.
First: on the host, the outcomes without any content:
`jq -c 'select(.hook == "bulk-read") | {ts, result, files, bytes, exit_status, claude_exit, model}' ~/.local/state/claude-hooks/$(date -u +%F).jsonl`.
auth: the OAuth token (`/run/secrets/claude_oauth_token`); rate_limited or model_unavailable: the model's quota or
availability; timeout: the `files` and `bytes` the timed-out calls delegated.
Rollback: `SHUNT_DISABLE=1` in the environment the sessions start from, or `sam.claude.bulkReader.enable = false`.

## ShuntSilent

Fires: on a host or worker whose series say `shunt="on"` (its declared `sam.claude.bulkReader.enable`: lenovo, acer's
slot pool1), the agent made a Bash call in the last hour (validate-bash logged it) but no Shunt hook has logged for 2 h, for an
hour; or a Shunt hook logged `error` (shunt-spill could not save an output) or `nostate` (shunt-read/shunt-bash could
not keep its state) in the collector's 24 h window. An off worker never fires, so the on/off comparison it guards is
the one between `shunt="on"` and `shunt="off"` series.
First: in the home it reads (the owner's on the host; a worker's is `/var/lib/workers/<worker>/home` on the host,
as root), `jq -r '.hooks.PreToolUse[].hooks[].command' .claude/settings.json | grep shunt` (no line: the hooks are
not registered, e.g. a skills pin without them), then the results without any content:
`jq -c 'select(.hook | startswith("shunt-")) | {ts, hook, result}' .local/state/claude-hooks/$(date -u +%F).jsonl | tail`.
`SHUNT_DISABLE=1` in the session's environment also silences them, and a session started before the switch keeps
the hooks it started with: restart it.
Rollback: `sam.claude.bulkReader.enable = false` for that host or worker (acer: the guest module in its configuration).

## ShuntHookOverhead

Fires: on a `shunt="on"` host or worker, Shunt's own Bash hooks (shunt-bash, shunt-spill) took over 250 ms per
Bash call in the collector's 24 h window (`shunt_hook_time_ms` over `shunt_bash_calls`), over at least 50 calls, for
an hour. shunt-read runs per Read, not per Bash call, and bulk-read's child replaces a read: neither is counted. The off side's
comparable is validate-bash's time per call (`shunt_hook_time_ms{hook="validate-bash"}`), which runs on or off, on
the Agent harnesses dashboard; a host that is slow on both sides is load, not Shunt. 250 ms is a starting bound, to be
set from the first day's readings.
First: the hooks' p95 in the alert's query, then the slowest records without any content:
`jq -c 'select(.hook | startswith("shunt-")) | {ts, hook, result, duration_ms}' .local/state/claude-hooks/$(date -u +%F).jsonl | sort -t: -k6 -n | tail`
in the home it reads.
Rollback: `sam.claude.bulkReader.enable = false` for that host or worker and switch, or `SHUNT_DISABLE=1` in the
environment its sessions start from. The window is 24 h, so it resolves once the slow calls age out of it.

## LLMGatewayDown

Fires: black-pi's Prometheus cannot scrape llm-gateway's admin port on acer (9091) for 5 minutes, or has no such
target. Pi, Open WebUI and factum have no LLM path.
First: on acer, `systemctl status llm-gateway` and `journalctl -u llm-gateway --since -15m`. A unit skipped, not
failed, has no `state.sqlite3` (the header of `modules/homelab/llm-gateway.nix`).

## LLMGatewayFreeFloorLow

Fires: every tier-2 (free floor) quota group has under 10 % of its daily allowance left, for 10 minutes. Requests fall
to msi or get a 429 until 00:00 UTC.
First: from lenovo, `curl -s http://acer-swift:9091/status | jq .quota_groups` for which group is spent.

## LLMGatewayBatchHittingReserve

Fires: llm-gateway refused a batch project's request in the last 15 minutes because only the interactive reserve of
the free quota is left (`interactive_reserve`).
First: from lenovo, `curl -s http://acer-swift:9091/status | jq '.projects, .quota_groups'`; the batch work waits for
00:00 UTC or moves to a paid tier.
