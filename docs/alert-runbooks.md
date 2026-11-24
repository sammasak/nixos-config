# Alert runbooks

One section per alert in `modules/homelab/monitoring/rules/homelab.yaml`, `modules/homelab/monitoring/rules/shunt.yaml`,
`modules/homelab/monitoring/rules/exec-pool.yaml` and Loki's ruler rules, `modules/homelab/monitoring/loki-rules/fake/homelab.yaml`;
each alert's `runbook_url` points at its heading here. The shipping alerts point at [shipping.md](shipping.md#alerts).

Every homelab, Shunt, execution pool, shipping and Loki-ruler alert carries the same annotations, held by the `monitoring-alert-annotations` check
(`flake-modules/monitoring-check.nix`, `scripts/check-alert-annotations.py`):

| annotation | holds |
|---|---|
| `summary` | one line: the symptom and the component |
| `description` | the observed condition, its threshold and duration, the affected host or service, the first safe step |
| `query` | the first diagnostic PromQL, runnable as is in Prometheus on black-pi (`{{ $labels.* }}` are filled in by Prometheus); the `grafana-dashboards` check parses it and holds its metric names and jobs. A Loki-ruler alert's is LogQL, for Grafana's Explore on the Loki data source, and that check does not read it |
| `runbook_url` | a heading in a tracked doc of this repo, on `main` |

The ntfy page (Alertmanager's webhook payload, `modules/homelab/monitoring/alertmanager.nix`) carries `summary`,
`description` and `Query: <query>`, and a tap opens `runbook_url`; all four also show in Prometheus's alert view. Run a PromQL query at `http://192.168.10.137:9090/graph`.

## HostExpectedOff

Fires: a sleeping host's node-exporter does not answer inside its planned power-off. Null route, never notifies; it
feeds the inhibit rules in `modules/homelab/monitoring/alertmanager.nix`.
First: nothing to do. If the host should be on, check its power window in `modules/core/fleet.nix`.

## NodeChronicNotReady

Fires: `up{job="node-exporter"}` is 0 for 15 minutes outside the host's planned power-off.
First: `ping` the host and `ssh` to it; on it, `systemctl status prometheus-node-exporter`.
Do not: mark the host `sleeps` to silence it.

## GpuTelemetryDown

Fires: the host's node-exporter answers but its nvidia-gpu exporter has not for 5 minutes.
First: on the host, `systemctl status prometheus-nvidia-gpu-exporter` and `nvidia-smi`; `journalctl -k | grep NVRM`.

## NodeOOMKill

Fires: `node_vmstat_oom_kill` increased in the last 15 minutes.
First: on the host, `journalctl -k --since -1h | grep -i 'killed process'` names the process and its cgroup.
Do not: raise a `MemoryMax` before the journal shows which unit hit it.

## UnitOOMKilled

Fires: systemd logged "A process of this unit has been killed by the OOM killer" for a system unit in the last 15
minutes (Loki's ruler on black-pi; `run-*`, `session-*` and `systemd-coredump@*` fold as the journal collector folds them). It
names the unit that NodeOOMKill only counts, so one kill pages both. Its `query` is LogQL, for Grafana's Explore.
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

## NodeSensorNearCritical

Fires: an hwmon sensor reads within 5 °C of its own critical mark for 15 minutes. `notify="none"`: alert list only.
First: whether a build or gate runs on the host (expected on msi and lenovo); outside one, check fans and airflow.

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
has no series and fails the unit instead (NodeSystemdUnitFailed).
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
Rollback: for herman on acer, remove `sam.claude.autoCompactWindow` from `hosts/acer-swift/configuration.nix` (an
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

## PrometheusTargetsMostlyDown

Fires: under 70 % of scrape targets are up for 10 minutes: the monitoring signal itself is suspect.
First: `http://192.168.10.137:9090/targets`; whether the down targets share a host, a job or the LAN.

## HomelabHealthScoreLow

Fires: `homelab:health:score` is below 70 for 15 minutes.
First: the query lists each `homelab:health:*` KPI; follow the one that fails its threshold in the score's rule.

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
error there (exit 75: the database is unavailable). Authentik shares the PostgreSQL cluster, so its health is the same check.
Do not: delete the textfile or write `exec_pool_queue_up 1` by hand; nothing dispatches from the queue yet, so there
is no task to rescue.
Rollback: drop the `exec-pool.nix` import from acer's configuration and deploy; the `exec_pool` database stays until
dropped by hand.

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
a1), the agent made a Bash call in the last hour (validate-bash logged it) but no Shunt hook has logged for 2 h, for an
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
