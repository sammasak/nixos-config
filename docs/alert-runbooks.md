# Alert runbooks

One section per alert in `modules/homelab/monitoring/rules/homelab.yaml` and `modules/homelab/monitoring/rules/shunt.yaml`;
each alert's `runbook_url` points at its heading here. The shipping alerts point at [shipping.md](shipping.md#alerts).

Every homelab, Shunt and shipping alert carries the same annotations, held by the `monitoring-alert-annotations` check
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

Fires: on a host that enables `homelab.shuntMetrics` (lenovo), `shunt-metrics.service` has not read the hook log
successfully for over 45 minutes, its runs kept failing for 20 minutes, or its unit exists but has never written
`/var/lib/shunt-metrics/shunt.prom`. A sleeping or disabled host never fires: the alert reads the collector's own
series and unit. The Shunt panels on Agent harnesses and ShuntDelegationFailing are blind while it fires.
First: on the host, `systemctl status shunt-metrics.timer shunt-metrics.service` and `journalctl -u shunt-metrics.service`;
the script names a failed scan's exception type there. `ls -l ~/.local/state/claude-hooks/` shows whether the hook log exists.
Do not: delete the textfile to silence it; a missing file fires as well.
Rollback: `homelab.shuntMetrics.enable = false` in the host's configuration and deploy; Shunt itself keeps working.

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
