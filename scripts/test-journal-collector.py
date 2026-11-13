"""homelab.journalCollector (modules/homelab/journal-collector.nix): Alloy ships the journal on msi-ms7758 only,
reads journald and nothing else, references no secret, and its readiness probe stays on the host.

Evaluation only: options, the generated config.alloy and the unit's serviceConfig, never a build."""
import re
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


hosts = gate_probe.section("journal-collector")
check({"msi-ms7758", "lenovo", "acer-swift", "black-pi"} <= set(hosts), f"every host is evaluated {sorted(hosts)}")
on = sorted(h for h, f in hosts.items() if f["enable"] or f["alloy"])
check(on == ["msi-ms7758"], f"the collector and Alloy run on msi-ms7758 only {on}")

m = hosts.get("msi-ms7758", {})
conf = m.get("config") or ""
svc = m.get("service") or {}

blocks = sorted(re.findall(r'^\s*([a-z_]+(?:\.[a-z_]+)+)\s+"[^"]*"\s*\{', conf, re.M))
check(blocks == ["loki.relabel", "loki.source.journal", "loki.write"],
      f"components: one journald source, its relabel and the Loki writer {blocks}")
check('job = "host-journal"' in conf and 'host = "msi-ms7758"' in conf and 'target_label  = "unit"' in conf,
      "labels: job host-journal (not a pod-log job), host and unit")
check(re.search(r'url = "http://[^"]+/loki/api/v1/push"', conf) is not None, "writes to a Loki push endpoint")

secretish = re.compile(r"sys\.env|local\.file|remote\.|basic_auth|bearer|password|/run/secrets", re.I)
check(not secretish.search(conf) and m.get("environmentFile") is None
      and not svc.get("LoadCredential") and not svc.get("EnvironmentFile"),
      "no secret: no credential, environment file or secret read in the config")

probe = svc.get("ExecStartPost") or ""
probe = " ".join(probe) if isinstance(probe, list) else probe
urls = re.findall(r"https?://[^\s'\"]+", probe)
check(urls == ["http://127.0.0.1:12345/-/ready"], f"readiness probe is Alloy's local ready endpoint only {urls}")
check("--server.http.listen-addr=127.0.0.1:12345" in m.get("flags", []), "Alloy's HTTP server listens on loopback only")
check(svc.get("Restart") == "on-failure" and svc.get("TimeoutStartSec") and svc.get("MemoryMax"),
      f"Restart=on-failure, a start timeout and MemoryMax {svc}")
sys.exit(1 if failed else 0)
