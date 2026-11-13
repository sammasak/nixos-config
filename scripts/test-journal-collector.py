"""homelab.journalCollector (modules/homelab/journal-collector.nix): Alloy ships the journal on msi-ms7758 only,
reads journald and nothing else, references no secret, keeps its readiness probe on the host, restarts on a config
change, drops the egress proxy's info access lines and pages ntfy (with retries) when it fails. The negative case enables the module on acer-swift in the probe only.

Evaluation only: options, the generated config.alloy and the unit, never a build."""
import json
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
check(kinds == ["loki.process", "loki.relabel", "loki.source.journal", "loki.write"],
      f"components: one journald source, its relabel, the drop stage and the Loki writer {kinds}")

src = next((b for (k, _), b in comps.items() if k == "loki.source.journal"), "")
relabel = next((l for k, l in comps if k == "loki.relabel"), None)
write = next((l for k, l in comps if k == "loki.write"), None)
proc = next((l for k, l in comps if k == "loki.process"), None)
check(f"relabel_rules = loki.relabel.{relabel}.rules" in src and f"forward_to = [loki.process.{proc}.receiver]" in src
      and f"forward_to = [loki.write.{write}.receiver]" in comps.get(("loki.process", proc), ""),
      "the source takes the relabel rules and forwards through the drop stage to the writer")
check('job = "host-journal"' in src and 'host = "msi-ms7758"' in src,
      "labels: job host-journal (not a pod-log job) and host")
check('max_age = "72h"' in src, "max_age 72h: the backlog survives msi's weekend power-off")
rel = comps.get(("loki.relabel", relabel), "")
check('source_labels = ["__journal__systemd_unit"] target_label = "unit"' in rel, "unit label from the systemd unit")
# order matters: the rewrites read the unit label the first rule sets, and the drop stage matches on its result
order = [(re.search(r'source_labels = \["([^"]*)"\]', r) or [None, "?"])[1]
         + "->" + (re.search(r'replacement = "([^"]*)"', r) or [None, "unit"])[1]
         for r in rel.split("rule {")[1:]]
check(order == ["__journal__systemd_unit->unit", "unit->transient", "unit->systemd-coredump"],
      f"relabel rules: exactly three, unit first, then the transient and coredump rewrites {order}")
rules = {}
for rule in rel.split("rule {")[1:]:
    rx = re.search(r'regex = "((?:[^"\\]|\\.)*)"', rule)
    to = re.search(r'replacement = "([^"]*)"', rule)
    if rx and to:
        rules[to[1]] = rx[1].replace("\\\\", "\\")
check(set(rules) == {"transient", "systemd-coredump"}, f"unit rewrites: transient and systemd-coredump {sorted(rules)}")
cases = {"session-12.scope": "transient", "run-r1a2b.service": "transient", "run-u7.scope": "transient",
         "run-p123-i456.scope": "transient", "systemd-coredump@0-1234-0.service": "systemd-coredump",
         "k3s.service": None, "sshd.service": None, "user@1000.service": None, "systemd-journald.service": None}
got = {u: next((to for to, rx in rules.items() if re.fullmatch(rx, u)), None) for u in cases}
check(got == cases, f"unit rewrites match transient and coredump units only {got}")
pc = comps.get(("loki.process", proc), "")
sel = re.search(r'stage\.match \{ selector = "\{unit = \\"([^"\\]+)\\"\}"', pc)
src_f = re.search(r'stage\.drop \{ source = "([^"]+)"', pc)
drop_rx = re.search(r'stage\.drop \{[^}]*expression = "((?:[^"\\]|\\.)*)"', pc)
json_f = re.search(r'stage\.json \{ expressions = \{([^}]*)\}', pc)
check(None not in (sel, src_f, drop_rx, json_f), "drop stage: a unit match, a JSON parse and a drop on its fields")


def shipped(unit, line):
    """The rendered match and drop stage applied to one line (Go regexp: unanchored search)."""
    if None in (sel, src_f, drop_rx, json_f) or unit != sel[1]:
        return True
    try:
        fields = json.loads(line)
    except ValueError:
        return True
    names = src_f[1].split(",")
    if not set(names) <= set(re.findall(r"([a-z_]+) = \"\"", json_f[1])) or any(n not in fields for n in names):
        return True
    return re.search(drop_rx[1].replace("\\\\", "\\"), ";".join(str(fields[n]) for n in names)) is None


egress = "dev-env-egress.service"
access = '{"level":"%s","ts":1.0,"logger":"http.log.access.anthropic-nats","msg":"handled request","status":%d}'
lines = {
    (egress, access % ("info", 200)): False,
    (egress, access.replace("anthropic", "otlp") % ("info", 204)): False,
    (egress, access % ("error", 502)): True,
    (egress, '{"level":"info","ts":1.0,"logger":"http.log","msg":"server running"}'): True,
    (egress, '{"level":"warn","ts":1.0,"logger":"http","msg":"HTTP/2 skipped because it requires TLS"}'): True,
    (egress, "Starting the egress proxy"): True,
    ("sshd.service", access % ("info", 200)): True,
}
got = {f"{u} {l[:60]}": shipped(u, l) for u, l in lines}
want = {f"{u} {l[:60]}": keep for (u, l), keep in lines.items()}
check(got == want, f"drops only info access lines of {egress} {got}")
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
check(re.search(r"curl .*--retry 3 .*-d \"alloy failed on msi-ms7758\" .*http://\S+", m.get("failed") or "") is not None,
      "journal-collector-failed posts the failure to ntfy, retrying 3 times")
check(unit.get("startLimitBurst") == 4 and unit.get("startLimitIntervalSec") == 600,
      f"start limit: 4 starts in 600 s, then failed {unit.get('startLimitBurst')}/{unit.get('startLimitIntervalSec')}")
check(isinstance(m.get("configPath"), str) and m["configPath"].startswith("/nix/store/")
      and m["configPath"] in (m.get("execStart") or ""),
      "the config is a store file named in ExecStart: a config change restarts Alloy (through the probe)")
check("alloy-config-check" in m.get("checks", []), f"the build validates the config (system.checks) {m.get('checks')}")
check(svc.get("RestartSec") == 30, f"RestartSec 30: four starts cannot burn out in seconds {svc.get('RestartSec')}")
sys.exit(1 if failed else 0)
