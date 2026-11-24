# Monitoring

Where each part of the fleet's monitoring runs, what reads what, and which build checks hold it. The source of truth
is the modules named here; this page only maps them.

## Where it runs

| host | service | listens on | read by |
|---|---|---|---|
| black-pi | Prometheus (`modules/homelab/monitoring/prometheus.nix`), 15 d or 1500 MB, OTLP and remote-write receivers on (either lets a `from` host write any series) | fleet address :9090 | Grafana; acer's alloy-otlp writes; Loki's ruler writes; lenovo's watchdog |
| black-pi | Alertmanager (`modules/homelab/monitoring/alertmanager.nix`), one unclustered instance | fleet address :9093 | Prometheus; Loki's ruler |
| black-pi | Grafana (`modules/homelab/monitoring/grafana.nix`), sign-in through Authentik only | fleet address :3000 | acer's Caddy (grafana.sammasak.dev) |
| black-pi | Loki (`loki.nix`), ruler on | fleet address :3100 | every fleet host's journal collector |
| black-pi | blackbox exporter (in `prometheus.nix`), probes of the public names | 127.0.0.1:9115 | Prometheus |
| every fleet host | node-exporter (`modules/homelab/monitoring/node-exporter.nix`), systemd collector and automatic service-restart counters on | fleet address :9100, black-pi alone | Prometheus |
| every fleet host | journal collector (`journal-collector.nix`), Alloy | 127.0.0.1:12345 | nothing (it pushes to Loki) |
| a host with `sam.fleet` `gpu = "nvidia"` | nvidia-gpu exporter (`modules/homelab/monitoring/gpu-exporter.nix`) | fleet address, black-pi alone | Prometheus |
| acer | alloy-otlp (`modules/homelab/monitoring/alloy-otlp.nix`), the harnesses' OTLP intake | 127.0.0.1:4318 behind otlp.sammasak.dev; metrics :12346 | Prometheus |
| acer | llm-gateway's admin listener | :9091 | Prometheus |
| acer | Caddy's metrics site (`modules/homelab/edge.nix`), plain HTTP: Caddy's `/metrics` and Authentik's two loopback metrics listeners at `/authentik/{server,worker}/metrics` | :9180, black-pi alone | Prometheus (jobs `caddy`, `authentik-server`, `authentik-worker`) |

Which host may reach which port is `sam.fleet.listeners` (`modules/core/fleet.nix`); `modules/core/network.nix` turns it
into firewall rules. The scrape jobs are in `prometheus.nix`. The node-exporter and nvidia-gpu targets come from `sam.fleet.hosts`, so a host
added there is scraped, labelled `node=<hostName>` and, if it `sleeps`, `sleeps="true"`.

GPU power metrics distinguish the requested software limit
(`nvidia_smi_power_limit_watts`) from the effective enforced limit
(`nvidia_smi_enforced_power_limit_watts`). Hardware and software thermal slowdown
also have separate `nvidia_smi_clocks_event_reasons_*_thermal_slowdown` gauges.
The GPU and LLM gateway dashboards show both; missing series remain unknown,
not proof of an inactive reason. The exporter fixture deliberately uses different
power limits and thermal flags and checks their emitted values. Source checks
do not replace driver/scrape acceptance after the exporter is activated.

What a host writes into node-exporter's textfile directory (`/run/node-exporter-textfile`):
- every fleet host: `nixos.prom`, the activated generation, NixOS version and toplevel (`pkgs/nixos-textfile`, at
  activation)
- acer: `open-webui-edge.prom`, the chat upstream socket (`open-webui.nix`)
- lenovo: `adguard.prom`, AdGuard's status and query counts, read from its loopback API every minute
  (`scripts/adguard-textfile.py`, `adguardhome.nix`)

Two collectors keep their own textfile directory, which node-exporter also reads: `shipping.prom` on lenovo
(`shipping-metrics.nix`) and `nav.prom` on acer, lenovo, asus and msi (`nav-metrics.nix`), plus one
`nav-guest-<name>.prom` per guest on a host with dev environments (acer, `/var/lib/nav-metrics-guests`).
The scheduled full gate on acer writes `scheduled-gate.prom` in its own, `/var/lib/scheduled-gate/metrics`
(`scheduled-gate.nix`, docs/shipping.md).

Every journal-collector host also exposes bounded local reader/export/filter counters
through `/run/journal-metrics/journal.prom`; see [delivery semantics and acceptance](journal-delivery-metrics.md).

Bounded labels: Caddy runs `metrics` without `per_host` (it would label any HTTPS Host as sent), so its series split by
server, not by name. Authentik gets the matched name without a client port as Host, and the Authentik jobs drop the
`authentik_outpost_*` family (its method label is the client's) and carry a `sample_limit`.

See [the measured improvement cycle](monitoring-improvement-cycle.md) for the fleet coverage matrix, repeatable baseline, issue ownership and before/after acceptance.

## Dashboards

`modules/homelab/monitoring/dashboards/*.json`, rendered by `dashboards.nix` and provisioned from
`/etc/grafana-dashboards` into the Observability folder.
- A dashboard declares `{"name": "node", "type": "custom"}`, and the fleet's hosts become its options; no dashboard
  lists a host by hand.
- Deleting a file deletes its dashboard at the next switch (`disableDeletion = false`). A dashboard edited in the UI
  cannot be saved: change the JSON.
- Agent harnesses, "On versus off": the table gives each host/worker's Shunt and window; compare per Bash call or
  main-thread request, never raw totals. "Shunt helps": on workers spill and redirect and send fewer context tokens
  per request than off ones, compactions per request not rising. "The 300K window helps": a worker with a 300K window
  compacts less per request than a default one with the same Shunt. Today no worker sets the window and acer's host sends no Claude
  events, so neither claim isolates until two workers differ in one setting.
  A guest's token and cost series carry `worker` (the relay's stamp), so tokens per session split by worker too.

## Rules and paging

- Prometheus loads `modules/homelab/monitoring/rules/*.yaml` (`homelab.yaml` rendered by `modules/homelab/monitoring/rules/homelab.nix` from the fleet's power windows), the
  llm-bench scorecard and the shipping rules from `modules/homelab/monitoring/rules/shipping.nix` (the list is in `prometheus.nix`).
- Loki's ruler (`homelab.loki.ruler`) evaluates the LogQL rules in `modules/homelab/monitoring/loki-rules/fake/`: it
  remote-writes recordings to Prometheus and sends alerts to Alertmanager, both on black-pi over lo. Prometheus's
  rule view does not list them; Loki's `/prometheus/api/v1/rules` does. The `loki-ruler-black-pi` check runs them.
  - `host_worker:claude_code_auto_compactions:count1m{host,worker}`: Claude Code's auto compactions per minute (#626),
    each minute counted once: a sum over a day is a lower bound (late lines, minutes Loki was down).
    ClaudeCompactionLoop (`homelab.yaml`) fires when one host or worker sums over 5 in an hour.
  - UnitOOMKilled (warning): systemd logged an OOM kill in a system unit, named in `oom_unit`.
- Alertmanager publishes every alert to lenovo's ntfy except Watchdog, InfoInhibitor, HostExpectedOff, any alert
  labelled `notify="none"` and any `severity="info"` alert (NodeCPUHighUsage): those go to a null receiver. The shipping team's alerts are muted at night.
- HostExpectedOff marks a sleeping host that is off as planned. Inhibit rules keyed on it silence what the power-off
  causes (`alertmanager.nix`).
- lenovo's watchdog (`cluster-watchdog.nix`) checks the pipeline from outside: Prometheus and Alertmanager ready, and
  Watchdog firing.
- Host pages in `homelab.yaml`, beside the reachability ones:
  - NodeSystemdUnitFailed (warning, 15 m): any failed service, socket, timer, target or path unit.
  - DnsDown (critical, 5 m): lenovo's AdGuard does not answer its status API.
  - DnsStatsStale (warning): `adguard.prom` has not been rewritten for over 5 min.
  - JournalEntriesDropped (warning, 5 m): Alloy's Loki writer dropped journal entries in the last 15 min on a host that is up.
  - JournalMetricsStale (warning, 10 m): the journal-metrics collection failed, is over 180 s old, or is missing on an up host.
  - BackupStale (warning, 10 m): a daily backup's last recorded success is over 36 h old.
  - BackupNeverRecorded (warning, 36 h): a backup has no valid success record.
  - BackupCollectorStale (warning, 15 m): the backup-metrics scan is over 900 s old, or acer or lenovo has no `backup.prom`.
  - OtlpWritesRejected (warning, 10 m): acer's alloy-otlp answered OTLP POSTs with 4xx/5xx in every 5 min window.
  - NodeTemperatureHigh (warning, 15 m): the Pi's `cpu-thermal` zone at 85 °C or more. x86 zones page no one.
  - NodeSensorNearCritical (warning, 15 m, `notify="none"`): an hwmon sensor within 5 °C of its own critical mark.
    msi and lenovo reach it through every gate, so it notifies no one. It shows in the alert list, in Fleet's
    "Alerts firing" count, and on the Hosts dashboard's hottest sensor.
  - GpuThermalThrottling (warning, 10 m): the GPU reports hardware thermal slowdown
    (`nvidia_smi_clocks_event_reasons_hw_thermal_slowdown`).
- Each homelab and shipping alert's `runbook_url` and first diagnostic `query`: [alert-runbooks.md](alert-runbooks.md).
- The upstream Prometheus and Alertmanager rules leave out what this deployment cannot fire: the cluster-consistency
  and remote-write/service-discovery alerts. Assertions in `alertmanager.nix` and `prometheus.nix` keep it unclustered
  and static, and name the rules to restore if that changes.

## Build checks

| check | holds |
|---|---|
| `grafana-dashboards` | every query on every dashboard: metric names against what the exporters really emit (node-exporter on its own fixtures with the deployed flags; the GPU check's output; Loki's, Alloy's, Caddy's and blackbox's name literals; llm-gateway's and Authentik's registrations; black-pi's Prometheus and Alertmanager and acer's alloy-otlp run on loopback (`scripts/monitoring-exposition.sh`); the writers' textfiles, AdGuard's from lenovo's sandboxed AdGuard; the OTLP allow-list; the rule files' records); PromQL through promtool, LogQL through logcli; jobs scraped or written; no host named by hand; every rule file Prometheus loads held to the same names and jobs; seeded failures, rule files included |
| `grafana-dashboard-removal` | Grafana itself, with black-pi's provider settings, deletes a removed file's dashboard and keeps ids across a restart |
| `gpu-telemetry-exporter` | the GPU exporter's fields against a fake nvidia-smi that heads the throttle fields `clocks_event_reasons`, as asus's driver does |
| `monitoring-alert-routes` | Alertmanager's routing (amtool) on black-pi's configuration: `notify="none"` and `severity="info"` reach no one, NodeTemperatureHigh and a warning reach ntfy, and the same alert without the label would notify |
| `monitoring-alert-annotations` | every homelab and shipping alert carries `summary`, `description`, `query` and a `runbook_url` naming a heading in a tracked doc ([alert-runbooks.md](alert-runbooks.md)); a rule file with no alert fails; seeds without a query, without an anchor, with a dangling anchor and with an empty file beside a good one fail it. The `grafana-dashboards` check holds each `query`'s PromQL and names |
| `monitoring-rules-tests` | `promtool test rules` on every file in `modules/homelab/monitoring/rules/tests`, against `homelab.yaml` as rendered |
| `monitoring-config-msi-ms7758`, `monitoring-rules-sleeping-hosts` | black-pi's Prometheus, Alertmanager and blackbox configs checked on an x86 seed; the sleeping-host rules per host |
| `loki-config-msi-ms7758`, `loki-ruler-black-pi`, `journal-collector-config-black-pi` | Loki's config, black-pi's ruler and rules end to end (synthetic lines to Prometheus and a stub Alertmanager) and the Pi's journal collector, on x86 |
| `alert-fire-resolve` (VM) | synthetic rules travel Prometheus and black-pi's Alertmanager configuration, its ntfy payload template included, to ntfy with lenovo's settings, read back through its poll API: one page per group with the exact title, tags, priority, click and body, firing then resolved; a page with no runbook or query, an oversized summary cut to 1000 characters, and a summary ending in a colon still arrive; the same colon body without the template's YAML guard is refused; the info twin reaches Alertmanager and no page. About 6 min: the resolved page waits for the 5m group_interval |
| `shipping-*` (`shipping-check.nix`) | the Shipping rules and dashboard |
| `caddy-edge-test` (gate, `scripts/test-caddy-edge.py`) | acer's Caddyfile through acer's Caddy; the deployed config run on loopback, where a stray name or Host port adds no series and Authentik sees only the served names |

black-pi is aarch64 and only evaluated on x86 hosts. Its own config checks (promtool, amtool) run when the Pi builds
its toplevel, which is why the checks above seed its modules onto msi.

Backup freshness and validation semantics: [completion metrics](backup-completion-metrics.md)
(#564/#600; source instrumentation and live receipts are separate).
