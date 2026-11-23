#!/usr/bin/env python3
"""The platform scorecard (pkgs/scorecard) on a fake Prometheus and Loki: a pass and a fail against the threshold, the
worst series named; no query, an empty result, an HTTP error, an error status, a NaN and a matrix each unknown with the
reason, never a pass; a metric whose record kind has nothing within its maximum age stale, and the kind table saying so;
a long-window average of good but old samples stale through its `fresh` guard, a refused guard unknown; by-hand unknown
with its reading. A backend that does not answer, or is not ready, exits 2 and leaves its metrics unknown while the
other backend's are still read. A `checkout` metric (registry-apps) from a copy of the checkout: today's 1/3 with
herman and llm-gateway named, one more registry entry or one more app a module runs moving the count, every app in a
pass, an app source of another form or no app at all unknown, and so each shape the text rule cannot read: a
callPackage it does not read as an entry, an overlay attr mentioned under modules/homelab in another form, and a
homelab module with `src = inputs.`, a `build*Package` or `inputs.<x>.packages`. The real metrics/targets.json against
backends that answer no query: every metric printed in its area, none but the checkout one a pass or a fail.
Run as `test-scorecard.py [the packaged scorecard]`."""
from __future__ import annotations

import http.server
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from typing import Any, ClassVar

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROGRAM = sys.argv[1:] or [sys.executable, str(ROOT / "pkgs/scorecard/scorecard.py")]

Answer = tuple[int, Any]


def vector(*samples: tuple[dict[str, str], str]) -> Answer:
    result = [{"metric": m, "value": [1_700_000_000, v]} for m, v in samples]
    return 200, {"status": "success", "data": {"resultType": "vector", "result": result}}


def fresh(kind: str, hours: int) -> str:
    return f'sum(count_over_time({{job="platform",kind="{kind}"}}[{hours}h]))'


class Fake(http.server.BaseHTTPRequestHandler):
    answers: ClassVar[dict[tuple[str, str], Answer]] = {}
    ready: ClassVar[dict[str, int]] = {"/-/ready": 200, "/ready": 200}

    def do_GET(self) -> None:
        url = urllib.parse.urlparse(self.path)
        if url.path in Fake.ready:
            code, body = Fake.ready[url.path], "ready"
        else:
            q = urllib.parse.parse_qs(url.query).get("query", [""])[0]
            code, payload = Fake.answers.get((url.path, q), (400, {"status": "error", "error": "no canned answer"}))
            body = payload if isinstance(payload, str) else json.dumps(payload)
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args: Any) -> None:
        pass


PROM, LOKI = "/api/v1/query", "/loki/api/v1/query"
AVAILABILITY = 'avg_over_time(probe_success{job="blackbox"}[14d])'
PROBED = 'time() - max(timestamp(probe_success{job="blackbox"})) < 900'
Fake.answers = {
    (PROM, "shipping_ok"): vector(({}, "0")),
    # the exporter stopped: the 14-day average still holds good old samples, the freshness guard finds none recent
    (PROM, AVAILABILITY): vector(({"instance": "a"}, "1")),
    (PROM, PROBED): vector(),
    (PROM, "shipping_guarded"): vector(({}, "0")),
    (PROM, "shipping_guard_ok"): vector(({}, "1")),
    (PROM, 'probe_success{job="blackbox"}'): vector(({"instance": "a"}, "1"), ({"instance": "b"}, "0.5")),
    (PROM, "shipping_empty"): vector(),
    (PROM, "shipping_bad"): (400, {"status": "error", "error": "parse error at char 3"}),
    (PROM, "shipping_status"): (200, {"status": "error", "error": "query timed out"}),
    (PROM, "shipping_nan"): (200, {"status": "success", "data": {"resultType": "scalar", "result": [1, "NaN"]}}),
    (PROM, "shipping_matrix"): (200, {"status": "success", "data": {"resultType": "matrix", "result": []}}),
    (LOKI, fresh("deploy", 336)): vector(({}, "3")),
    (LOKI, fresh("gate", 96)): vector(),
    (LOKI, 'sum(count_over_time({job="platform",kind="deploy"} | logfmt [1d])) or vector(0)'): vector(({}, "0")),
    (LOKI, 'sum(count_over_time({job="platform",kind="deploy"} | logfmt | result!="ok" [30d]))'): vector(({}, "2")),
}


def metric(mid: str, area: str, query: str | None, backend: str | None = None, op: str = "<=",
           value: float | None = 0, fresh: str | None = None) -> dict[str, Any]:
    threshold = None if query is None else ({"op": op} if value is None else {"op": op, "value": value})
    return {"id": mid, "area": area, "state": "live" if query else "new", "query": query, "backend": backend,
            "threshold": threshold, "fresh": fresh, "target": f"target of {mid}"}



SEEDED = {
    "areas": {"A": "First", "B": "Second"},
    "max_age_hours": {"deploy": 336, "gate": 96},
    "metrics": [
        metric("no-query", "A", None),
        metric("passes", "A", "shipping_ok", "prometheus"),
        metric("fails", "A", 'probe_success{job="blackbox"}', "prometheus", ">=", 0.99),
        metric("empty", "A", "shipping_empty", "prometheus"),
        metric("http-error", "A", "shipping_bad", "prometheus"),
        metric("error-status", "B", "shipping_status", "prometheus"),
        metric("nan", "B", "shipping_nan", "prometheus"),
        metric("matrix", "B", "shipping_matrix", "prometheus"),
        metric("quiet-kind", "B", 'sum(count_over_time({job="platform",kind="gate"} [1d]))', "loki"),
        metric("loki-passes", "B", 'sum(count_over_time({job="platform",kind="deploy"} | logfmt [1d])) or vector(0)',
               "loki"),
        metric("guarded", "B", "shipping_guarded", "prometheus", fresh="shipping_guard_ok"),
        metric("old-samples", "B", AVAILABILITY, "prometheus", ">=", 0.99, fresh=PROBED),
        metric("guard-error", "B", "shipping_guarded", "prometheus", fresh="shipping_guard_unanswered"),
        metric("by-hand", "B", 'sum(count_over_time({job="platform",kind="deploy"} | logfmt | result!="ok" [30d]))',
               "loki", "by-hand", None),
    ],
}


def run(targets: dict[str, Any] | pathlib.Path, prometheus: str, loki: str) -> tuple[int, str, dict[str, list[str]]]:
    with tempfile.TemporaryDirectory() as tmp:
        path = targets if isinstance(targets, pathlib.Path) else pathlib.Path(tmp) / "targets.json"
        if not isinstance(targets, pathlib.Path):
            path.write_text(json.dumps(targets))
        # a proxy variable would send the fake backends' localhost traffic elsewhere
        env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
        env.update(SCORECARD_PROMETHEUS_URL=prometheus, SCORECARD_LOKI_URL=loki)
        out = subprocess.run([*PROGRAM, str(path)], env=env, capture_output=True, text=True, timeout=60,
                             check=False)
    rows = {c[0]: c[1:] for line in out.stdout.splitlines() if line.startswith("| ") and not line.startswith("| Metric")
            and not line.startswith("| Kind") for c in [[x.strip() for x in line.strip("|").split(" | ")]]}
    return out.returncode, out.stdout + out.stderr, rows


def closed_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"

rc, out, rows = run(SEEDED, url, url)
verdict = {k: v[-1] for k, v in rows.items()}
check(rc == 0, f"both backends answering: exit 0 (rc {rc}) {'' if rc == 0 else out}")
check(out.index("## A. First") < out.index("| no-query ") < out.index("## B. Second") < out.index("| nan "),
      "each metric is printed in its area's table, in order")
check(rows.get("passes", [None])[0] == "0" and verdict.get("passes") == "pass",
      f"a reading within its threshold passes ({rows.get('passes')})")
check(verdict.get("fails") == "fail" and rows["fails"][0] == "worst 0.5 {instance=b} of 2",
      f"one series outside its threshold fails the metric, the worst one named ({rows.get('fails')})")
check(verdict.get("no-query") == "unknown: no query (new)", f"no query is unknown ({verdict.get('no-query')})")
check(verdict.get("empty") == "unknown: empty result", f"an empty result is unknown ({verdict.get('empty')})")
check(verdict.get("http-error") == "unknown: HTTP 400: parse error at char 3",
      f"a query the backend refuses is unknown with its error ({verdict.get('http-error')})")
check(verdict.get("error-status") == "unknown: status error: query timed out",
      f"an error status in a 200 is unknown with its error ({verdict.get('error-status')})")
check(verdict.get("nan") == "unknown: a reading is not a number", f"a NaN reading is unknown ({verdict.get('nan')})")
check((verdict.get("matrix") or "").startswith("unknown: result type 'matrix'"),
      f"a matrix is unknown ({verdict.get('matrix')})")
check(verdict.get("quiet-kind") == "stale: gate: no record in 96 h",
      f"a metric reading a kind quiet past its max age is stale ({verdict.get('quiet-kind')})")
check(rows.get("gate", [None, None])[1] == "stale: no record in 96 h"
      and rows.get("deploy", [None, None])[1] == "fresh",
      f"the kind table: gate stale, deploy fresh ({rows.get('gate')}, {rows.get('deploy')})")
check(verdict.get("loki-passes") == "pass",
      f"a Loki metric on a fresh kind is read and passes ({verdict.get('loki-passes')})")
check(verdict.get("by-hand") == "unknown: judged by hand" and rows["by-hand"][0] == "2",
      f"a by-hand target is unknown, its reading shown ({rows.get('by-hand')})")
check(verdict.get("guarded") == "pass",
      f"a metric whose freshness guard answers is read and passes ({verdict.get('guarded')})")
check(verdict.get("old-samples") == f"stale: no fresh sample ({PROBED})",
      f"a long-window average of good but old samples is stale, not a pass ({verdict.get('old-samples')})")
check(verdict.get("guard-error") == "unknown: freshness: HTTP 400: no canned answer",
      f"a freshness guard the backend refuses is unknown ({verdict.get('guard-error')})")
check("Metrics: pass 3, fail 1, stale 2, unknown 8" in out, "the summary counts each verdict")

down = f"http://127.0.0.1:{closed_port()}"
rc, out, rows = run(SEEDED, down, url)
verdict = {k: v[-1] for k, v in rows.items()}
check(rc == 2 and "Unreachable: prometheus unreachable" in out, f"Prometheus not answering: exit 2, said so (rc {rc})")
check(all(verdict[m].startswith("unknown: prometheus unreachable") for m in ("passes", "fails", "empty")),
      f"its metrics are unknown, not a pass ({[verdict[m] for m in ('passes', 'fails', 'empty')]})")
check(verdict.get("loki-passes") == "pass", "Loki's metrics are still read")

Fake.ready["/ready"] = 503
rc, out, rows = run(SEEDED, url, url)
verdict = {k: v[-1] for k, v in rows.items()}
Fake.ready["/ready"] = 200
check(rc == 2 and "Unreachable: loki not ready (HTTP 503)" in out,
      f"Loki answering not ready: exit 2, said so (rc {rc})")
check(verdict.get("loki-passes", "").startswith("unknown: deploy: loki not ready")
      and rows.get("deploy", ["", ""])[1].startswith("unknown: loki not ready"),
      f"a Loki metric and its kind are unknown, not stale or a pass"
      f" ({verdict.get('loki-passes')}, {rows.get('deploy')})")

real = json.loads((ROOT / "metrics/targets.json").read_text())
REGISTRY_APPS = next(m for m in real["metrics"] if m["id"] == "registry-apps")


def registry_apps(edit: Any = None) -> tuple[str, str]:
    """registry-apps' reading and verdict, from a copy of the files it reads with `edit(tree)` applied."""
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp)
        for f in ("flake.lock", "apps/registry.json", "flake-modules/overlays.nix"):
            (tree / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / f, tree / f)
        shutil.copytree(ROOT / "modules/homelab", tree / "modules/homelab")
        if edit:
            edit(tree)
        (tree / "metrics").mkdir()
        (tree / "metrics/targets.json").write_text(json.dumps(dict(SEEDED, metrics=[REGISTRY_APPS])))
        _, _, rows = run(tree / "metrics/targets.json", url, url)
    reading, _, verdict = rows.get("registry-apps", ["", "", ""])
    return reading, verdict


def edit_json(path: str, fn: Any) -> Any:
    def go(tree: pathlib.Path) -> None:
        data = json.loads((tree / path).read_text())
        fn(data)
        (tree / path).write_text(json.dumps(data))
    return go


def register(*names: str) -> Any:
    def fn(r: dict[str, Any]) -> None:
        for n in names:
            r["apps"][n] = {"source": {"repo": f"sammasak/{n}", "rev": "0" * 40, "narHash": "sha256-x"}}
    return edit_json("apps/registry.json", fn)


def new_app(src: str, use: str = "pkgs.newApp") -> Any:
    def go(tree: pathlib.Path) -> None:
        overlays = tree / "flake-modules/overlays.nix"
        overlays.write_text(overlays.read_text().replace("        llmGateway = final.callPackage", f"""\
        newApp = final.callPackage ../pkgs/new-app/package.nix {{
          {src}
        }};
        llmGateway = final.callPackage""", 1))
        module = f"{{ pkgs, ... }}: {{ systemd.services.x.path = [ {use} ]; }}\n"
        (tree / "modules/homelab/new-app.nix").write_text(module)
    return go


def lock_input(tree: pathlib.Path) -> None:
    edit_json("flake.lock", lambda lock: (lock["nodes"].update(
        {"new-app": {"original": {"type": "github", "owner": "sammasak", "repo": "new-app"}}}),
        lock["nodes"]["root"]["inputs"].update({"new-app": "new-app"})))(tree)


check(registry_apps() == ("1/3; not in the registry: herman, llm-gateway", "fail"),
      f"registry-apps today: alert-bridge in, herman and llm-gateway named as not yet ({registry_apps()})")
check(registry_apps(register("llm-gateway")) == ("2/3; not in the registry: herman", "fail"),
      f"one more registry entry moves the count ({registry_apps(register('llm-gateway'))})")
check(registry_apps(register("llm-gateway", "herman")) == ("3/3", "pass"), "every app in the registry passes")
grown = registry_apps(lambda t: (new_app("src = inputs.new-app;")(t), lock_input(t)))
check(grown == ("1/4; not in the registry: herman, llm-gateway, new-app", "fail"),
      f"an app a new modules/homelab module runs is counted by the rule, no list to update ({grown})")
odd = registry_apps(new_app("src = fetchFromGitHub { owner = \"x\"; repo = \"y\"; };"))
check(odd[1].startswith("unknown: flake-modules/overlays.nix: newApp runs under modules/homelab, its src neither"),
      f"an app source the rule cannot read is unknown, not skipped ({odd})")


def homelab_module(body: str) -> Any:
    return lambda t: (t / "modules/homelab/outside.nix").write_text(f"{{ inputs, pkgs, ... }}: {{ {body} }}\n")


def one_line(tree: pathlib.Path) -> None:
    overlays = tree / "flake-modules/overlays.nix"
    overlays.write_text(overlays.read_text().replace("        llmGateway = final.callPackage", """\
        newApp = final.callPackage ../pkgs/new-app/package.nix { src = inputs.new-app; };
        llmGateway = final.callPackage""", 1))
    (tree / "modules/homelab/new-app.nix").write_text("{ pkgs, ... }: { systemd.services.x.path = [ pkgs.newApp ]; }\n")
    lock_input(tree)


# shapes the text rule cannot read: each fails closed, never a count without the app
H = "unknown: modules/homelab/outside.nix: "
# one_line adds one call to the overlay's own, which its entries read
CALLS = (ROOT / "flake-modules/overlays.nix").read_text().count("callPackage") + 1
for name, edit, want in [
        ("a callPackage the reader does not read as an entry (one line)", one_line,
         f"unknown: flake-modules/overlays.nix: {CALLS} callPackage calls, {CALLS - 1} read as a package entry"),
        ("an overlay attr used under modules/homelab other than pkgs.<attr> ((with pkgs; newApp))",
         lambda t: (new_app("src = inputs.new-app;", "(with pkgs; newApp)")(t), lock_input(t)),
         "unknown: modules/homelab/new-app.nix: newApp is mentioned in a form other than pkgs.newApp"),
        ("src = inputs.<x> in a homelab module",
         homelab_module("x = pkgs.stdenv.mkDerivation { name = \"x\"; src = inputs.new-app; };"),
         H + r"\bsrc\s*=\s*inputs\. ('src = inputs.')"),
        ("a buildRustPackage in a homelab module", homelab_module("x = pkgs.rustPlatform.buildRustPackage { };"),
         H + r"\bbuild[A-Za-z]*Package\b ('buildRustPackage')"),
        ("inputs.<x>.packages in a homelab module",
         homelab_module("environment.systemPackages = [ inputs.new-app.packages.${pkgs.system}.default ];"),
         H + r"\binputs\.[\w-]+\.packages\b ('inputs.new-app.packages')")]:
    got = registry_apps(edit)
    check(got[1].startswith(want), f"{name} reads unknown, naming the file and the pattern ({got})")

gone = registry_apps(lambda t: shutil.rmtree(t / "modules/homelab"))
check(gone[1].startswith("unknown: no app found"), f"no app at all is unknown, not a pass ({gone})")

rc, out, rows = run(ROOT / "metrics/targets.json", url, url)
verdicts = {m["id"]: rows.get(m["id"], [None])[-1] for m in real["metrics"]}
check(rc == 0 and all(v for v in verdicts.values()), f"the real targets: every metric printed (rc {rc}, missing "
      f"{[k for k, v in verdicts.items() if not v]})")
check(verdicts.get("registry-apps") == "fail" and rows["registry-apps"][0].startswith("1/3"),
      f"the real targets: registry-apps read from this checkout ({rows.get('registry-apps')})")
check(all(v.split(":")[0] in ("unknown", "stale") for k, v in verdicts.items() if v and k != "registry-apps"),
      f"no answer, no pass: every metric unknown or stale ({sorted({v.split(':')[0] for v in verdicts.values() if v})})"
      )
check(all(f"## {a}. {t}" in out for a, t in real["areas"].items()) and all(k in rows for k in real["max_age_hours"]),
      "the real targets: all four areas and every record kind are printed")

server.shutdown()
finish()
