"""homelab.journalCollector (modules/homelab/journal-collector.nix): Alloy ships the journal on msi-ms7758 only,
reads journald and nothing else, references no secret, keeps its readiness probe on the host, restarts on a config
change and pages ntfy when it fails. The negative case enables the module on acer-swift in the probe only.

Evaluation only: options, the generated config.alloy and the unit, never a build."""
import re
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def enabled(hosts):
    return sorted(h for h, f in hosts.items() if f["enable"] or f["alloy"])


def norm(text):
    return re.sub(r"\s*=\s*", " = ", re.sub(r"\s+", " ", text or ""))


def components(conf):
    """{(kind, label): body} for each top-level component of a normalised config."""
    heads = list(re.finditer(r'(?:^| )([a-z_]+(?:\.[a-z_]+)+) "([^"]*)" \{', conf))
    return {(m[1], m[2]): conf[m.end():(heads[i + 1].start() if i + 1 < len(heads) else len(conf))]
            for i, m in enumerate(heads)}


r = gate_probe.section("journal-collector")
hosts = r["hosts"]
check({"msi-ms7758", "lenovo", "acer-swift", "black-pi"} <= set(hosts), f"every host is evaluated {sorted(hosts)}")
check(enabled(hosts) == ["msi-ms7758"], f"the collector and Alloy run on msi-ms7758 only {enabled(hosts)}")
seeded = enabled({**hosts, "acer-swift": r["seeded"]})
check(seeded == ["acer-swift", "msi-ms7758"], f"negative case: enabling it on acer-swift shows in the msi-only check {seeded}")

m = hosts.get("msi-ms7758", {})
conf = norm(m.get("config"))
comps = components(conf)
kinds = sorted(k for k, _ in comps)
check(kinds == ["loki.relabel", "loki.source.journal", "loki.write"],
      f"components: one journald source, its relabel and the Loki writer {kinds}")

src = next((b for (k, _), b in comps.items() if k == "loki.source.journal"), "")
relabel = next((l for k, l in comps if k == "loki.relabel"), None)
write = next((l for k, l in comps if k == "loki.write"), None)
check(f"relabel_rules = loki.relabel.{relabel}.rules" in src and f"forward_to = [loki.write.{write}.receiver]" in src,
      "the source takes the relabel rules and forwards to the writer")
check('job = "host-journal"' in src and 'host = "msi-ms7758"' in src,
      "labels: job host-journal (not a pod-log job) and host")
check('max_age = "72h"' in src, "max_age 72h: the backlog survives msi's weekend power-off")
rel = comps.get(("loki.relabel", relabel), "")
check('source_labels = ["__journal__systemd_unit"] target_label = "unit"' in rel, "unit label from the systemd unit")
check('replacement = "transient"' in rel and "session-" in rel and "run-" in rel,
      "session scopes and run- units collapse to unit=transient")
wr = comps.get(("loki.write", write), "")
check(re.search(r'url = "http://[^"]+/loki/api/v1/push"', wr) is not None and "max_backoff_retries = 0" in wr,
      "writes to a Loki push endpoint and retries forever (the journal holds the backlog)")

secretish = re.compile(r"sys\.env|local\.file|remote\.|basic_auth|bearer|password|/run/secrets", re.I)
svc = m.get("service") or {}
check(not secretish.search(conf) and m.get("environmentFile") is None
      and not svc.get("LoadCredential") and not svc.get("EnvironmentFile"),
      "no secret: no credential, environment file or secret read in the config")

probe = svc.get("ExecStartPost") or ""
probe = " ".join(probe) if isinstance(probe, list) else probe
urls = re.findall(r"https?://[^\s'\"]+", probe)
check(urls == ["http://127.0.0.1:12345/-/ready"], f"readiness probe is Alloy's local ready endpoint only {urls}")
check("--server.http.listen-addr=127.0.0.1:12345" in m.get("flags", []), "Alloy's HTTP server listens on loopback only")
budget = re.search(r"--retry-max-time (\d+)", probe)
timeout = svc.get("TimeoutStartSec")
check(budget is not None and isinstance(timeout, int) and int(budget[1]) < timeout,
      f"the probe gives up ({budget and budget[1]} s) before the start timeout ({timeout} s)")
check(bool(svc.get("MemoryMax")), f"MemoryMax set {svc.get('MemoryMax')}")

unit = m.get("unit") or {}
check(unit.get("onFailure") == ["journal-collector-failed.service"],
      f"a failed Alloy starts journal-collector-failed {unit.get('onFailure')}")
check(re.search(r"curl .*-d \"alloy failed on msi-ms7758\" .*http://\S+", m.get("failed") or "") is not None,
      "journal-collector-failed posts the failure to ntfy")
check(unit.get("startLimitBurst") == 3 and unit.get("startLimitIntervalSec") == 600,
      f"start limit: 3 starts in 600 s, then failed {unit.get('startLimitBurst')}/{unit.get('startLimitIntervalSec')}")
check(m.get("configSource") in (unit.get("restartTriggers") or []), "a config change restarts Alloy (through the probe)")
sys.exit(1 if failed else 0)
