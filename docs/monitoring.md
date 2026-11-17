# Monitoring

Where each part of the fleet's monitoring runs, what reads what, and which build checks hold it. The source of truth
is the modules named here; this page only maps them.

## Where it runs

| host | service | listens on | read by |
|---|---|---|---|
| black-pi | Prometheus (`monitoring/prometheus.nix`), 15 d or 1500 MB, OTLP receiver on | fleet address :9090 | Grafana; acer's alloy-otlp writes; lenovo's watchdog |
| black-pi | Alertmanager (`monitoring/alertmanager.nix`), one unclustered instance | fleet address :9093 | Prometheus |
| black-pi | Grafana (`monitoring/grafana.nix`), sign-in through Authentik only | fleet address :3000 | acer's Caddy (grafana.sammasak.dev) |
| black-pi | Loki (`loki.nix`) | fleet address :3100 | every fleet host's journal collector |
| black-pi | blackbox exporter (in `prometheus.nix`), probes of the public names | 127.0.0.1:9115 | Prometheus |
| every fleet host | node-exporter (`monitoring/node-exporter.nix`), systemd collector on | fleet address :9100, black-pi alone | Prometheus |
| every fleet host | journal collector (`journal-collector.nix`), Alloy | 127.0.0.1:12345 | nothing (it pushes to Loki) |
| a host with `sam.fleet` `gpu = "nvidia"` | nvidia-gpu exporter (`monitoring/gpu-exporter.nix`) | fleet address, black-pi alone | Prometheus |
| acer | alloy-otlp (`monitoring/alloy-otlp.nix`), the harnesses' OTLP intake | 127.0.0.1:4318 behind otlp.sammasak.dev; metrics :12346 | Prometheus |
| acer | llm-gateway's admin listener | :9091 | Prometheus |
| lenovo | alert-bridge (`alert-bridge.nix`): Alertmanager's webhook to ntfy | :9099, black-pi alone | Alertmanager |

The scrape jobs are in `prometheus.nix`. The node-exporter and nvidia-gpu targets come from `sam.fleet.hosts`, so a host
added there is scraped, labelled `node=<hostName>` and, if it `sleeps`, `sleeps="true"`.

What a host writes into node-exporter's textfile directory (`/run/node-exporter-textfile`):
- every host: `nixos.prom`, the activated generation, NixOS version and toplevel (`scripts/nixos-textfile.sh`, at
  activation)
- acer: `open-webui-edge.prom`, the chat upstream socket (`open-webui.nix`)

## Dashboards

`modules/homelab/monitoring/dashboards/*.json`, rendered by `dashboards.nix` and provisioned from
`/etc/grafana-dashboards` into the Observability folder.
- A dashboard declares `{"name": "node", "type": "custom"}`, and the fleet's hosts become its options; no dashboard
  lists a host by hand.
- Deleting a file deletes its dashboard at the next switch (`disableDeletion = false`). A dashboard edited in the UI
  cannot be saved: change the JSON.

## Rules and paging

- Prometheus loads `rules/*.yaml`, the llm-bench scorecard and `rules/shipping.nix` (the list is in `prometheus.nix`).
- Alertmanager sends every alert to the alert bridge except Watchdog, InfoInhibitor and HostExpectedOff (a null
  receiver). The shipping team's alerts are muted at night.
- HostExpectedOff marks a sleeping host that is off as planned. Inhibit rules keyed on it silence what the power-off
  causes (`alertmanager.nix`).
- lenovo's watchdog (`cluster-watchdog.nix`) checks the pipeline from outside: Prometheus and Alertmanager ready, and
  Watchdog firing.

## Build checks

| check | holds |
|---|---|
| `grafana-dashboards` | every query on every dashboard: metric names against what the exporters really emit (node-exporter on its own fixtures with the deployed flags, the GPU check's output, Loki's, Alloy's and blackbox's name literals, llm-gateway's registrations, the OTLP allow-list, the rule files' records); PromQL through promtool, LogQL through logcli; jobs scraped or written; no host named by hand; seeded failures |
| `grafana-dashboard-removal` | Grafana itself, with black-pi's provider settings, deletes a removed file's dashboard and keeps ids across a restart |
| `gpu-telemetry-exporter` | the GPU exporter's fields against a fake nvidia-smi |
| `monitoring-config-msi-ms7758`, `monitoring-rules-sleeping-hosts` | black-pi's Prometheus, Alertmanager and blackbox configs checked on an x86 seed; the sleeping-host rules per host |
| `loki-config-msi-ms7758`, `journal-collector-config-black-pi` | Loki's config and the Pi's journal collector, on x86 |
| `alert-bridge-sources` | the bridge admits Alertmanager's host alone |
| `shipping-*` (`shipping-check.nix`) | the Shipping rules and dashboard |

black-pi is aarch64 and only evaluated on x86 hosts. Its own config checks (promtool, amtool) run when the Pi builds
its toplevel, which is why the checks above seed its modules onto msi.
