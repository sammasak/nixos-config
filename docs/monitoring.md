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

## Inside and outside names

Two name spaces, both from `sam.fleet`:

- Outside: `<site>.sammasak.dev`, through Caddy on the edge, with Authentik where the site has it (`edge.nix`).
- Inside: every listener and ntfy as `<listener>.fleet.sammasak.dev` (`sam.fleet.zone`), with its port, for
  example `http://prometheus.fleet.sammasak.dev:9090`, `http://loki.fleet.sammasak.dev:3100`,
  `http://alertmanager.fleet.sammasak.dev:9093`, `http://store-cache-acer-swift.fleet.sammasak.dev:5000`. lenovo's
  AdGuard answers each with its serving host's LAN address (`adguardhome.nix`), so the fleet and its slots resolve
  it; no login, the firewall's `from` is the boundary. A listener's `dnsName` and `dnsUrl` give the name.

The inside names point straight at the serving host, not at the edge, so monitoring and the caches keep working
when acer or Caddy is what broke; the cost is the port in the URL. Services keep `url` (the address), so nothing
they do depends on DNS. Neither can be answered from outside: `edge.nix` fails evaluation on a site or certificate
in the zone, `adguardhome.nix` on a hand-written rewrite in it, and black-pi's `InsideNamePublic` fires when 1.1.1.1
answers one. A name in the zone with no listener falls to the `*.sammasak.dev` rewrite, the edge, which serves
nothing there.

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
  - UnitOOMKilled (warning): systemd logged an OOM kill in a system unit, named in `oom_unit`; while it fires, it
    inhibits NodeOOMKill on the same host, so one kill pages once.
- Alertmanager publishes every alert to lenovo's ntfy except Watchdog, HostExpectedOff, any alert labelled
  `notify="none"` and any `severity="info"` alert (no rule sets either today): those go to a null receiver. The shipping team's alerts are muted at night.
- HostExpectedOff marks a sleeping host that is off as planned. Inhibit rules keyed on it silence what the power-off
  causes (`alertmanager.nix`); TargetDown leaves that host's targets out itself (`homelab:node:off_as_planned`).
- lenovo's watchdog (`cluster-watchdog.nix`) checks the pipeline from outside: Prometheus and Alertmanager ready, and
  Watchdog firing.
- Host pages in `homelab.yaml`, beside the reachability ones:
  - NodeSystemdUnitFailed (warning, 15 m): any failed service, socket, timer, target or path unit.
  - NodeSystemdCollectorFailed (warning, 10 m): node exporter's systemd collector failed on a host, so every
    `node_systemd_unit_state` series of that host may be gone; while it fires, StoreUploadStale, NodeSystemdUnitFailed and
    ShuntCollectorStale's failed-unit leg cannot be trusted on that host, the failed-unit tables get a "systemd
    collector failed" row added for it, and real failed units it still reported can appear with that row
    ([runbook](alert-runbooks.md#nodesystemdcollectorfailed)).
  - DnsDown (critical, 5 m): lenovo's AdGuard does not answer its status API.
  - DnsStatsStale (warning): `adguard.prom` has not been rewritten for over 5 min.
  - JournalEntriesDropped (warning, 5 m): Alloy's Loki writer dropped journal entries in the last 15 min on a host that is up.
  - JournalMetricsStale (warning, 10 m): the journal-metrics collection failed, is over 180 s old, or is missing on an up host.
  - BackupStale (warning, 10 m): a daily backup's last recorded success is over 36 h old.
  - BackupNeverRecorded (warning, 36 h): a backup has no valid success record.
  - BackupCollectorStale (warning, 15 m): the backup-metrics scan is over 900 s old, or acer or lenovo has no `backup.prom`.
  - OtlpWritesRejected (warning, 10 m): acer's alloy-otlp answered OTLP POSTs with 4xx/5xx in every 5 min window.
  - NodeTemperatureHigh (warning, 15 m): the Pi's `cpu-thermal` zone at 85 °C or more. x86 hosts page through NodeHwmonTemperatureHigh below.
  - NodeHwmonTemperatureHigh (warning, 10 m): a host's hottest hwmon sensor above 92 °C, less sensors marked critical at 105 °C or more (msi).
  - NodeCpuThrottlingHigh (warning, 15 m): a host's core throttle rate above twice its 7 day mean plus 10/s.
  - NodeFanStuck (warning, 5 m): every fan of lenovo or msi at 0 rpm (65535 ignored) while it is above 80 °C.
  - GpuThermalThrottling (warning, 10 m): the GPU reports hardware thermal slowdown
    (`nvidia_smi_clocks_event_reasons_hw_thermal_slowdown`).
- Each homelab and shipping alert's `runbook_url` and first diagnostic `query`: [alert-runbooks.md](alert-runbooks.md).
- The upstream rules leave out what this deployment cannot fire or deliver: the Alertmanager cluster alerts, the
  remote-write, service-discovery and target, label and body-size limit alerts, RAID and bonding (no host has either),
  and the two that only say Prometheus cannot reach Alertmanager (lenovo's watchdog pages that). Assertions in
  `alertmanager.nix` and `prometheus.nix` keep it unclustered, static and unlimited, and name the rules to restore if
  that changes. Each rule file's header names what it leaves out.

## Build checks

| check | holds |
|---|---|
| `grafana-dashboards` | every query on every dashboard: metric names against what the exporters really emit (node-exporter on its own fixtures with the deployed flags; the GPU check's output; Loki's, Alloy's, Caddy's and blackbox's name literals; llm-gateway's and Authentik's registrations; black-pi's Prometheus and Alertmanager and acer's alloy-otlp run on loopback (`scripts/monitoring-exposition.sh`); the writers' textfiles, AdGuard's from lenovo's sandboxed AdGuard; the OTLP allow-list; the rule files' records); PromQL through promtool, LogQL through logcli; jobs scraped or written; no host named by hand; every rule file Prometheus loads held to the same names and jobs; seeded failures, rule files included |
| `grafana-dashboard-removal` | Grafana itself, with black-pi's provider settings, deletes a removed file's dashboard and keeps ids across a restart |
| `gpu-telemetry-exporter` | the GPU exporter's fields against a fake nvidia-smi that heads the throttle fields `clocks_event_reasons`, as asus's driver does |
| `monitoring-alert-routes` | Alertmanager's routing (amtool) on black-pi's configuration: `notify="none"` and `severity="info"` reach no one, NodeTemperatureHigh and a warning reach ntfy, and the same alert without the label would notify |
| `monitoring-alert-annotations` | every alert in a rule file black-pi's Prometheus loads, every shipping and every Loki-ruler alert carries `summary`, `description`, `query` and a `runbook_url` naming a heading in a tracked doc ([alert-runbooks.md](alert-runbooks.md)), or upstream's page for a kube-prometheus-stack rule; a rule file with no alert fails; seeds without a query, without an anchor, with a dangling anchor and with an empty file beside a good one fail it. The `grafana-dashboards` check holds each `query`'s PromQL and names |
| `monitoring-rules-tests` | `promtool test rules` on every file in `modules/homelab/monitoring/rules/tests`, against `homelab.yaml` as rendered |
| `monitoring-config-msi-ms7758`, `monitoring-rules-sleeping-hosts` | black-pi's Prometheus, Alertmanager and blackbox configs checked on an x86 seed; the sleeping-host rules per host |
| `loki-config-msi-ms7758`, `loki-ruler-black-pi`, `journal-collector-config-black-pi`, `journal-collector-config-lenovo` | Loki's config, black-pi's ruler and rules end to end (synthetic lines to Prometheus and a stub Alertmanager), the Pi's journal collector on x86, and lenovo's ntfy stages in real Alloy: publish lines cut to alert-topic receipts, any other ntfy line naming `message_body` dropped as `ntfy_body_unparsed` |
| `alert-fire-resolve` (VM) | synthetic rules travel Prometheus and black-pi's Alertmanager configuration, its ntfy payload template included, to ntfy with lenovo's settings, read back through its poll API: one page per group with the exact title, tags, priority, click and body, firing then resolved; a page with no runbook or query, an oversized summary cut to 1000 characters, and a summary ending in a colon still arrive; the same colon body without the template's YAML guard is refused; the info twin reaches Alertmanager and no page. About 6 min: the resolved page waits for the 5m group_interval |
| `shipping-*` (`shipping-check.nix`) | the Shipping rules and dashboard |
| `caddy-edge-test` (gate, `scripts/test-caddy-edge.py`) | acer's Caddyfile through acer's Caddy; the deployed config run on loopback, where a stray name or Host port adds no series and Authentik sees only the served names |

black-pi is aarch64 and only evaluated on x86 hosts. Its own config checks (promtool, amtool) run when the Pi builds
its toplevel, which is why the checks above seed its modules onto msi.

Backup freshness and validation semantics: [completion metrics](backup-completion-metrics.md)
(#564/#600; source instrumentation and live receipts are separate).

## Alert inventory (26 Nov)

Every alert name with a firing `ALERTS` series in the 7 days to 26 Nov 17:05 UTC (#624), read through black-pi's
Prometheus from an acer pool slot. Rule files are under `modules/homelab/monitoring/rules/`; times are UTC; "window
start" means firing at 19 Nov 17:05, the start of the window. Routes are from `alertmanager.nix`: "ntfy" is the
default route to lenovo's `homelab-alerts` topic, "ntfy, night mute" the `team="shipping"` route (19:00 to 07:30
UTC), "null" a route that notifies no one. Alertmanager's API, Loki's ruler API and ntfy were not readable from the
slot (403, 403, unreachable), so no ntfy message per alert could be read: "unknown" there means not found, not
missing. The per-alert receipts besides the cited issue comment are alert-investigations and `cluster-watchdog`
(lenovo) reading the alert from Alertmanager's active alerts: that proves evaluation into Alertmanager, not a page.
Alertmanager's webhook (ntfy) counters over the same 7 days: 202 notifications sent, 0 failed, the last at 26 Nov
16:49; 4754 suppressed by the night mute and 1929 by inhibition.

| Alert | Sev | Rule | Signal (producer) | Route | Fired in 7 d | Last receipt | Gap / owner |
|---|---|---|---|---|---|---|---|
| ScheduledGateRed | warning | `shipping.nix` | `homelab_scheduled_gate_red` (`scheduled-gate.nix`, acer) | ntfy, night mute | 24 Nov 15:02 to now, firing; 16 episodes, 48 h | ntfy unknown: no line names it. Webhook send 26 Nov 17:59:03 (counter 85 to 86), 44 s after its re-fire at 17:58:19 with no other routed alert changing within 5 min (inferred); alert-investigations 18:14 (cap reached) | firing at 18:35, not muted or inhibited then (night mute from 19:00); per-alert log gap (below); flaps, ending and re-firing within a minute; #825 |
| RetroDueStepFailsRepeat | warning | `shipping.nix` | `shipping_gate_step_failures` and the gate-green timestamps (`shipping-metrics.nix`, lenovo; `scheduled-gate.nix`) | ntfy, night mute | window start to 26 Nov 16:07; 2 episodes, 166 h | Alertmanager: alert-investigations 26 Nov 01:24 (not started, GitHub unreachable); ntfy unknown | never resolved for 166 of 168 h; #826 |
| GateFailRateHigh | warning | `shipping.nix` | `shipping_gate_fail_ratio`, `shipping_gate_runs_counted` (`shipping-metrics.nix`) | ntfy, night mute | 25 Nov 18:38 to now, firing; 1 episode, 22 h | ntfy unknown: no line names it. Webhook send by 25 Nov 18:39:33 (counter 41 to 42), at most 53 s after it started at 18:38:40 with no other routed alert changing within 5 min (inferred); its 12 h repeat fell in the night mute, and the morning release (26 Nov 07:32 to 07:34, 4 sends) does not say which shipping group each was | firing at 18:35, not muted or inhibited then; per-alert log gap (below) |
| DeployRolledBack | warning | `shipping.nix` | `shipping_deploy_rollbacks_open` (`shipping-metrics.nix`) | ntfy, night mute | 23 Nov 09:08 to 26 Nov 07:37 (lenovo); 3 episodes, 43 h | unknown | no receipt found |
| EscapeFound | warning | `shipping.nix` | `shipping_escapes` (`shipping-metrics.nix`) | ntfy, night mute | 24 Nov 21:08 to 25 Nov 05:37; 1 episode, 8 h | unknown | no receipt found |
| HostBehindMain | warning | `shipping.nix` | `shipping_deploy_lag_hours` (`shipping-metrics.nix`), `up` | ntfy, night mute | 20 Nov 12:08 to 24 Nov 08:37 (lenovo); 2 episodes, 69 h | unknown | no receipt found |
| ScheduledGateOverdue | warning | `shipping.nix` | `homelab_scheduled_gate_behind_since_timestamp_seconds` (`scheduled-gate.nix`) | ntfy, night mute | 24 Nov 14:50 to 14:56 | unknown | no receipt found |
| OpenIssuesGrowing | warning | removed (63c239a3) | replaced by OpenIssuesUntouched | ntfy, night mute | 20 Nov 20:10 to 24 Nov 06:09; 4 episodes, 65 h | unknown | rule gone; none |
| ExecPoolSlotMemoryKills | warning | `exec-pool.yaml` | `exec_pool_memory_kills_total` (`pkgs/exec-pool` runner; acer, msi) | ntfy | 25 Nov 12:56 to now, firing; 5 episodes, 12 h | ntfy unknown: no line names it. Webhook send 26 Nov 16:45:33 (counter 76 to 77) on this group's 5 min tick, after msi joined at 16:45:22 (inferred); acer's start at 16:19:52 shares one send (16:20:33) with ScheduledGateRed's re-fire in the same minute, so which group it was is unknown; alert-investigations 17:02 (cap reached) | firing at 18:35 (acer, msi), not muted or inhibited; per-alert log gap (below); #827 |
| ExecPoolPushesRefused | warning | `exec-pool.yaml` | `exec_pool_push_filter_pushes_total{result="refused"}` (`pkgs/exec-pool-push-filter`, acer) | ntfy | 26 Nov 03:50 to 04:49 (pool1 to pool3) | unknown | no receipt found; cause unknown |
| ExecPoolParkPushFailing | warning | `exec-pool.yaml` | `exec_pool_park_push_failures_total` (`pkgs/exec-pool` runner, acer) | ntfy | 26 Nov 01:28 to 02:25 | unknown | upstream internet outage (#624 comment, 26 Nov); no receipt found |
| ExecPoolNeedsReview | warning | `exec-pool.yaml` | `exec_pool_attempts{state="needs_review"}` (`pkgs/exec-pool` queue, acer) | ntfy | 25 Nov 19:54 to 21:57; 2 h | unknown | no receipt found |
| ExecPoolSessionStalled | warning | `exec-pool.yaml` | `exec_pool_session_stalled` (`pkgs/exec-pool` queue, acer) | ntfy | 25 Nov 07:10 to 13:18; under 1 h firing | unknown | no receipt found |
| NodeOOMKill | warning | `homelab.yaml` | `node_vmstat_oom_kill` (`node-exporter.nix`) | ntfy; inhibited by UnitOOMKilled on its node | window start to now, firing (acer, msi; also lenovo, asus); 31 episodes, 9 h | ntfy 24 Nov 03:28:48 firing, 03:53:48 resolved (acer; #624 comment, 24 Nov), the newest that names it; alert-bridge `published "[WARNING] NodeOOMKill"` 23 Nov 18:27:48 (Loki). Resolved sends 26 Nov 17:53:33 and 17:57:33 (counter 83 to 85) after acer (17:48) and msi (17:52) resolved, no other routed change (inferred) | resolved 26 Nov 17:52, not firing at 18:35; per-alert log gap (below); 31 episodes; whether UnitOOMKilled inhibited any is unknown (Loki ruler API 403) |
| NodeSystemdUnitFailed | warning | `homelab.yaml` | `node_systemd_unit_state{state="failed"}` (`node-exporter.nix`) | ntfy | 22 Nov 23:16 to 26 Nov 13:04 (last msi `store-upload.path`); 6 episodes, 9 h | Alertmanager: alert-investigations reported on #879, 26 Nov 12:50; ntfy unknown | #879 |
| NodeSystemSaturation | warning | `node-exporter.yaml` | `node_load1` over CPU count (`node-exporter.nix`) | ntfy | 23 Nov 12:07 to now, firing (acer); 3 episodes | ntfy unknown: no line names it. Webhook sends 26 Nov 17:29:33 (counter 81 to 82) 46 s after its start at 17:28:47, and 17:44:33 (82 to 83) after it resolved at 17:40, the second with no other routed change (inferred) | resolved 26 Nov 17:40, not firing at 18:35; per-alert log gap (below); no `team` label, so the default route, no night mute |
| NodeFilesystemSpaceFillingUp | warning | `node-exporter.yaml` | `node_filesystem_avail_bytes` (`node-exporter.nix`) | ntfy | 26 Nov 12:05 to 14:32 (asus `/`, `/var/lib/workers`) | unknown | no receipt found |
| NodeCpuThrottlingHigh | warning | `homelab.yaml` | `homelab:node:cpu_core_throttles:rate5m` from `node_cpu_core_throttles_total` (`node-exporter.nix`) | ntfy | 26 Nov 07:47 to 10:36 (acer); 2 episodes | unknown | no receipt found |
| NodeTextFileCollectorScrapeError | warning | `node-exporter.yaml` | `node_textfile_scrape_error` (`node-exporter.nix`) | ntfy | 24 Nov 07:17 to 26 Nov 07:01; 4 episodes | unknown | the series names no file, so which textfile failed is unknown |
| ShuntCollectorStale | warning | `shunt.yaml` | `shunt_collector_success_timestamp_seconds`, `shunt_collector_failed` (`shunt-metrics.nix`) | ntfy | 24 Nov 16:27 to 18:38 (acer `a1`, `herman`) | unknown | no receipt found |
| AlertInvestigationFailed | warning | `alert-investigations.yaml` | `homelab_alert_investigations_total{outcome="failed"}`, `homelab_alert_investigations_up` (`alert-investigations.nix`, lenovo) | ntfy | 25 Nov 20:13 to 26 Nov 07:23; 3 episodes, 9 h | unknown | its rule failed to evaluate from 26 Nov 01:20 until the `investigated` label fix, now live; #624 comments of 25 and 26 Nov |
| PrometheusRuleFailures | critical | `prometheus.yaml` | `prometheus_rule_evaluation_failures_total` (Prometheus itself) | ntfy | 26 Nov 01:40 to 02:55 | unknown | cause was AlertInvestigationFailed's labelset; no receipt found |
| TargetDown | warning | `general.yaml` | `up` of every job (`prometheus.nix`) less `homelab:node:off_as_planned` | ntfy | window start to 25 Nov 02:02 (`node-exporter`, `nvidia-gpu`); 4 episodes, 87 h | unknown (24 Nov: suppressed by HostExpectedOff) | firing 87 h, mostly inhibited; no receipt found |
| HostExpectedOff | none | `homelab.yaml` | `homelab:node:off_as_planned` (`up` and the power windows, `homelab.nix`) | null, by design | 7 episodes, 103 h | none expected; its inhibitions are the 1929 above (all sources) | none |
| Watchdog | none | `general.yaml` | `vector(1)` | null; lenovo's `cluster-watchdog` reads it | always firing | `cluster-watchdog` ntfy reply `"title":"watchdog OK"`, topic `homelab-watchdog`, 26 Nov 18:40:05 (Loki) | none; firing at 18:35, routed to null by design |
| NodeCPUHighUsage | info | removed (a3d60af0) | | null (info) | 23 Nov 09:43 to 12:32 | none expected | rule gone; none |
| NodeSensorNearCritical | warning | removed (a3d60af0) | | ntfy | 23 Nov 12:07 to 12:33 | unknown | rule gone; none |

Known signal, route and a last receipt of any kind: 7 of 27 (ScheduledGateRed, RetroDueStepFailsRepeat,
ExecPoolSlotMemoryKills, NodeSystemdUnitFailed and Watchdog by a reader of Alertmanager, NodeOOMKill by an ntfy
message, HostExpectedOff by design). A phone receipt per alert: 1 of 27 (NodeOOMKill, 24 Nov). Loki-ruler alerts
(UnitOOMKilled, PoolCostPerMergedChangeHigh) do not enter `ALERTS`, so whether they fired is unknown.

Queries, each over `$PROMETHEUS_URL` unless named:

- Classes: `count by (alertname, severity) (max_over_time(ALERTS{alertstate="firing"}[7d]))`
- First and last firing: `min by (alertname) (min_over_time(timestamp(ALERTS{alertstate="firing"})[7d:1m]))`, and
  `max` of the same; per series with `max_over_time(timestamp(ALERTS{alertstate="firing",alertname="X"})[7d:5m])`
- Episodes and hours: `query_range` of `count by (alertname) (ALERTS{alertstate="firing"})`, step 300 s, a gap over
  one step starting a new episode (an episode under 5 min can be missed)
- Rule, labels and health: `/api/v1/rules`
- Delivery counters: `sum by (integration) (increase(alertmanager_notifications_total[7d]))`, the same for
  `alertmanager_notifications_failed_total` and `alertmanager_notification_requests_failed_total`,
  `sum by (reason) (increase(alertmanager_notifications_suppressed_total[7d]))`, and the last send
  `max_over_time(timestamp(changes(alertmanager_notifications_total{integration="webhook"}[2m]) > 0)[7d:1m])`
- Receipts in Loki (`$LOKI_ADDR`): `{unit="alert-investigations.service"}` and `{unit="cluster-watchdog.service"}`;
  `{unit="ntfy-sh.service"}` carries only server stats, no alert name
- Receipts for the six still firing at 17:05, read again 26 Nov 18:35 to 18:45 UTC: `ALERTS{alertstate="firing"}`;
  Alertmanager's `/api/v2/alerts` (readable at 18:35, unlike at 17:05 as the paragraph above says;
  `status.inhibitedBy`, `mutedBy`, `silencedBy`, `startsAt`; its `/api/v2/status`, `/api/v2/silences` and
  `/api/v2/alerts/groups` still 403); the raw
  `alertmanager_notifications_total{integration="webhook"}` samples (30 s scrape) set against each alert's
  `ALERTS` transitions over 26 h at 15 s steps. Webhook failures over 7 d: 0
  (`alertmanager_notifications_failed_total`, `alertmanager_notification_requests_failed_total`). "Inferred" marks
  a send whose time fits that alert's start (group wait 30 s), resolve or group tick (5 min) and no other routed
  alert's: the counter carries no alert name, so it is not a receipt
- Loki: `{unit="alertmanager.service"}` and `{unit=~".*alertmanager.*"}` (no series since black-pi's oldest line,
  23 Nov 19:00), `{unit="alert-bridge.service"}` (its `published "..."` lines, the last 23 Nov 18:52, then removed
  in 0e086e5b), `{job="host-journal"} |= "<alertname>"` for each of the six, and
  `{unit="cluster-watchdog.service"}` for ntfy's JSON reply to each watchdog publish
- Per-alert log gap: since alert-bridge went, nothing logs which alert a notification carried. Alertmanager logs a
  sent notification only at debug level, ntfy-sh only its server stats, and ntfy itself and the Loki ruler API were
  not reachable from the slot (timeout, 403)
