# Fleet monitoring baseline — 19 November 2026

Tracking [#600](https://github.com/sammasak/nixos-config/issues/600). Source `origin/main` was `2d4ff1e2`; live APIs queried at approximately 18:08–18:11 UTC. Grafana's provisioned Pi Agents file matched this source. These are receiver observations, not proof every host runs that SHA.

| Signal | Observation |
|---|---|
| Scrapes | All 23 configured targets up at capture; seven blackbox probes successful |
| Failure alert | `RetroDueStepFailsRepeat{step="nixos-flake-check"}` firing; five broad flake-check failures in the seven-day collector window, plus a separately labelled check failure |
| Host health | No observed failed systemd units; zero OOM-kill increments over 24h and zero textfile scrape errors on all five monitored hosts |
| Memory used | Acer 19.9%, ASUS 5.2%, black-pi 34.1%, Lenovo 53.3%, MSI 12.3% |
| Root free | Acer 786.6 GiB, ASUS 415.5 GiB, black-pi 16.6 GiB, Lenovo 297.7 GiB, MSI 105.4 GiB; no immediate disk-space tuning justified |
| Monitoring overhead | Prometheus 292.1 MiB resident, Loki 209.3 MiB resident, 25,772 head series; point samples, not peaks |
| CPU data quality | Black-pi's conventional 24h busy calculation was -8.86%; five-minute idle rates 1.036–1.051 s/s per CPU, no idle counter resets. Do not use this value for capacity decisions. #601 investigates |
| Restart coverage | `count(node_systemd_service_restart_total)` returned no series; flag disabled in source before this change |
| Gate sample | Last 20 counted runs: acer-herman 16, fail ratio 18.75%, median 1397s; ASUS 4, fail ratio 25%, median 658.5s. Different workload mix, not a speed or quality comparison |
| Journal coverage | All five fleet hosts present. 24h counts: Acer 50,579; ASUS 45,963; black-pi 278,903; Lenovo 20,937; MSI 29,329. Naked-pi is not in these fleet targets |
| Loki noise | About 8,695 INFO `get or create table` lines out of roughly 10,124 Loki-unit lines in one hour (~86%). #602 narrows the filter only after source/fixture validation |
| Gateway events | 24h: 3,221 `ollama_attempt` connection failures and 3,221 WARN records; possible duplicate reporting, not necessarily 6,442 requests. Also 48 cloud attempt rate limits, 30 HTTP 503 and 21 transport errors. Investigate expected sleeping-backend behavior and fallback before changing it |
| Pilot visibility | Three direct ASUS pilot assignments absent from Pi Loki telemetry. Server journal correlation recovered timings/tokens; it cannot provide durable per-run identity. #494 owns correction |

Queries are preserved in `scripts/monitoring-baseline.py`. Additional log classification queries used:

```logql
sum by (level,event,result,status) (count_over_time({job="host-journal",unit="llm-gateway.service"} | json [24h]))
topk(10, sum by (msg,level) (count_over_time({job="host-journal",host="black-pi",unit="loki.service"} | logfmt [1h])))
```

The current journal privacy filters intentionally omit certain sensitive units. Absence there is policy, not silent data loss. Receiver `up` does not prove a host journal writer delivers successfully. Backup completion/restore, direct-run telemetry, per-unit CPU attribution, queue wait and daily-use acceptance remain incomplete; the [coverage matrix](../monitoring-improvement-cycle.md) assigns each to existing work.

No before/after benefit, model ranking, or live activation is claimed by this baseline. Scrape averages across sleeping periods do not establish an outage. A successful blackbox scrape (`up`) and a successful HTTP probe (`probe_success`) are separate measurements.
