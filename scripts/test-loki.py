"""homelab.loki (modules/homelab/loki.nix): enabled on no host yet; seeded on msi in the probe only, the rendered
config matches the k3s chart (single binary, filesystem, tsdb v13, 72h plus 720h for the two agent streams,
compactor retention, no auth, no usage reporting), loki -verify-config passed on it, Loki listens on loopback and
adds no firewall rule unless sources are listed, and a failed Loki always pages ntfy.

Evaluation plus the probe build (which realises upstream's validate-loki-conf), never a host build."""
import json
import os
import re
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


r = gate_probe.section("loki")
hosts = r["hosts"]
check({"msi-ms7758", "lenovo", "acer-swift", "black-pi"} <= set(hosts), f"every host is evaluated {sorted(hosts)}")
on = sorted(h for h, f in hosts.items() if f["enable"] or f["loki"])
check(on == [], f"no host runs Loki natively yet: merging switches nothing {on}")

s = r["seeded"]
d = s["defaults"]
check(d == {"listenAddress": "127.0.0.1", "port": 3100, "retention": "72h", "allowedSources": [], "ntfyUrl": None},
      f"defaults: loopback, 3100, 72h, no firewall source, ntfyUrl required (no default) {d}")
check("dport 3100" not in r["msiRules"], "msi's firewall has no Loki rule")
loc = r["local"]
check(loc["http"] == "127.0.0.1" and "http://127.0.0.1:3100/ready" in loc["probe"] and "dport 3100" not in loc["rules"],
      f"default instance: HTTP and probe on loopback, no firewall rule {loc['http']}")
anyb = r["any"]
check(anyb["http"] == "0.0.0.0" and "http://127.0.0.1:3100/ready" in anyb["probe"],
      "listenAddress 0.0.0.0: the probe asks 127.0.0.1")

c = s["configuration"]
data = s["dataDir"]
check(c.get("auth_enabled") is False, "auth_enabled false, as in the chart")
check(c.get("analytics") == {"reporting_enabled": False}, "usage reporting off")
srv = c.get("server", {})
check(srv.get("http_listen_address") == "192.0.2.10" and srv.get("http_listen_port") == 3100,
      f"HTTP on the configured address and port {srv.get('http_listen_address')}:{srv.get('http_listen_port')}")
check(srv.get("grpc_listen_address") == "127.0.0.1", f"gRPC on loopback only {srv.get('grpc_listen_address')}")
com = c.get("common", {})
check(com.get("replication_factor") == 1 and com.get("ring", {}).get("kvstore", {}).get("store") == "inmemory",
      "single binary: replication 1, in-memory ring (no memberlist port)")
paths = [com.get("path_prefix"), com.get("storage", {}).get("filesystem", {}).get("chunks_directory"),
         com.get("storage", {}).get("filesystem", {}).get("rules_directory"), c.get("compactor", {}).get("working_directory")]
check(data == "/var/lib/loki" and paths == [data, f"{data}/chunks", f"{data}/rules", f"{data}/compactor"],
      f"filesystem storage in the chart's layout under the loki user's home (upstream creates it, mode 0700) {paths}")
check(c.get("schema_config") == {"configs": [{"from": "2024-01-01", "store": "tsdb", "object_store": "filesystem",
                                              "schema": "v13", "index": {"prefix": "loki_index_", "period": "24h"}}]},
      "schema: the chart's one tsdb v13 period from 2024-01-01, 24h index")
lim = c.get("limits_config", {})
streams = sorted((x["selector"], x["period"]) for x in lim.get("retention_stream", []))
check(lim.get("retention_period") == "72h", f"retention 72h {lim.get('retention_period')}")
check(streams == [('{job="pi-agent"}', "720h"), ('{observer="harness"}', "720h")],
      f"the two agent telemetry streams keep 30 days {streams}")
check(lim.get("ingestion_rate_mb") == 8 and lim.get("ingestion_burst_size_mb") == 16, "ingestion limits 8/16 MB")
check(lim.get("reject_old_samples") is True and lim.get("reject_old_samples_max_age") == "168h",
      "old samples rejected after 168h (the collector's 72h backlog stays under it)")
check(c.get("ingester", {}).get("wal", {}).get("replay_memory_ceiling") == "512MB",
      "WAL replay ceiling 512MB, under MemoryMax (the 4GB default would OOM in a loop)")
comp = c.get("compactor", {})
check(comp.get("retention_enabled") is True and comp.get("delete_request_store") == "filesystem",
      "the compactor applies retention")

exec_start = s["execStart"]
conf = re.search(r"--config\.file=(\S+)", exec_start)
conf = conf[1] if conf else ""
check(s["extraFlags"] == [] and conf.endswith("-validate-loki-conf"),
      f"no extra flags, so ExecStart names upstream's validated config {conf}")
check(os.path.exists(conf), "the probe build ran loki -verify-config on the rendered file (validate-loki-conf exists)")
if os.path.exists(conf):
    with open(conf) as f:
        check(json.load(f) == c, "the validated file is the rendered configuration")

svc = s["service"]
unit = s["unit"]
check(s["user"] == "loki" and svc.get("User") == "loki", "a static loki user, so copied data can be chowned to it")
probe = svc.get("ExecStartPost") or ""
urls = re.findall(r"https?://[^\s'\"]+", probe)
check(urls == ["http://192.0.2.10:3100/ready"], f"readiness probe is Loki's own /ready only {urls}")
budget = re.search(r"--retry-max-time (\d+)", probe)
timeout, rs = svc.get("TimeoutStartSec"), svc.get("RestartSec")
check(budget is not None and isinstance(timeout, int) and int(budget[1]) < timeout,
      f"the probe gives up ({budget and budget[1]} s) before the start timeout ({timeout} s)")
check(unit.get("startLimitBurst") == 3 and isinstance(rs, int)
      and 3 * (timeout + rs + 90) <= (unit.get("startLimitIntervalSec") or 0),
      f"three failed starts, each with a full 90 s stop, fit in the start-limit window {unit}")
check(svc.get("MemoryMax") == "1G" and svc.get("CPUQuota") == "50%",
      f"MemoryMax 1G and CPUQuota 50%, the chart's limits {svc.get('MemoryMax')} {svc.get('CPUQuota')}")
check((unit.get("environment") or {}).get("GOMEMLIMIT") == "900MiB", "GOMEMLIMIT 900MiB under MemoryMax")
check(svc.get("ProtectSystem") == "strict" and svc.get("ReadWritePaths") == [data]
      and svc.get("CapabilityBoundingSet") == "" and svc.get("NoNewPrivileges") is True
      and svc.get("PrivateDevices") is True and "@system-service" in (svc.get("SystemCallFilter") or []),
      "hardened: read-only system but the state dir, no capabilities, syscall filter")
check(unit.get("onFailure") == ["loki-failed.service"], f"a failed Loki starts loki-failed {unit.get('onFailure')}")
check(re.search(r'curl -fsS -m 10 --retry 3 --retry-all-errors --retry-max-time 60 .*-d "loki failed on msi-ms7758" .*http://\S+',
                s["failed"] or "") is not None, "loki-failed posts the failure to ntfy, with bounded retries")

check("ip saddr 192.0.2.0/24 tcp dport 3100 accept" in s["rules"] and 3100 not in s["tcpPorts"],
      "listed sources get a scoped rule (mkDualBackendFirewall), never allowedTCPPorts")
check(s["failing"] == [], f"the seeded config passes its assertions {s['failing']}")
check(any("homelab.loki.allowedSources" in m for m in r["loopbackOpen"]),
      f"sources with a loopback address fail an assertion {r['loopbackOpen']}")
check(any("networking.firewall.enable" in m for m in r["noFirewall"]),
      "a non-loopback address without the firewall fails an assertion")
sys.exit(1 if failed else 0)
