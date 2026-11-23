# Alert runbooks

One section per alert in `modules/homelab/monitoring/rules/homelab.yaml`; each alert's `runbook_url` points at its
heading here. The shipping alerts point at [shipping.md](shipping.md#alerts).

Every homelab and shipping alert carries the same annotations, held by the `monitoring-alert-annotations` check
(`flake-modules/monitoring-check.nix`, `scripts/check-alert-annotations.py`):

| annotation | holds |
|---|---|
| `summary` | one line: the symptom and the component |
| `description` | the observed condition, its threshold and duration, the affected host or service, the first safe step |
| `query` | the first diagnostic PromQL, runnable as is in Prometheus on black-pi (`{{ $labels.* }}` are filled in by Prometheus); the `grafana-dashboards` check parses it and holds its metric names and jobs |
| `runbook_url` | a heading in a tracked doc of this repo, on `main` |

alert-bridge puts `summary` and `description` in the ntfy page; `query` and `runbook_url` show in Alertmanager and
Prometheus's alert view. Run the query at `http://192.168.10.137:9090/graph`.

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
