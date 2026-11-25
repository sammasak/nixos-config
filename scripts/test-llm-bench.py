"""pkgs/llm-bench (nixos-config#493): #492's G1 bench (scripts/ollama-g1-bench.sh) run against the fake Ollama and
imported with `import-g1` under #492's G1 rule, the capacity run end to end, the statistics and verdicts on fixed inputs,
the MSI import, and what may leave a run: no prompt, completion or run ID in an aggregate, and every committed
scorecard file is an aggregate."""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pkgs", "llm-bench"))
import llm_bench as lb  # noqa: E402

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): ") + what)
    failed += not ok


# quantile floors: p50 from 5 samples, p95 from 20, never a number below them
check(lb.quantile([1.0] * 4, 0.5) is None and lb.quantile([1.0] * 5, 0.5) == 1.0, "p50 needs 5 samples")
check(lb.quantile(list(range(19)), 0.95) is None and lb.quantile(list(range(1, 21)), 0.95) == 19, "p95 needs 20 samples (nearest rank)")
check(lb.quantile([None] * 30, 0.5) is None, "missing values are not samples")
check(lb.quantile([None, 4, 0, 3, 1, 2], 0.5) == 2, "quantile ignores missing values")
check(lb.quantile([None, 0, 1, 2, 3], 0.5) is None, "missing values do not count toward sample floor")
check(lb.metric(None, "s", "client_measured", 4)["source"] == "insufficient_samples"
      and lb.metric(None, "s", "prometheus")["source"] == "unavailable", "a null value says why it is null")

limits = lb.thresholds()
check(limits["status"].startswith("proposed"), "the thresholds are marked proposed until the owner confirms them")


def g1_result(ctx=4096, msi=None, warnings=(), **values):
    m = {k: lb.metric(None, "", "unavailable") for k in
         ("vram_headroom_bytes", "gpu_offload_ratio", "decode_tps_p50", "ttft_warm_p95", "cold_load_p50")}
    for k, v in values.items():
        m[k] = lb.metric(v, "", "provider_reported")
    return lb.judge_g1({"model": "qwen2.5-coder:7b-instruct-q4_K_M", "ctx": ctx, "metrics": m, "warnings": list(warnings)}, msi, limits)


good = {"vram_headroom_bytes": 1.0 * lb.GIB, "gpu_offload_ratio": 1.0, "decode_tps_p50": 30.0,
        "ttft_warm_p95": 1.0, "cold_load_p50": 10.0}
check(g1_result(**good)["g1"] == "pass" and g1_result(**good)["fit"] == "yes", "every check inside its threshold: G1 pass and a fit")
bad = g1_result(**{**good, "decode_tps_p50": 20.0})
check(bad["g1"] == "no-go" and bad["checks"]["decode"]["threshold"] == 24, "without an msi row the G1 decode bar is 24 tok/s, for every model")
vs = g1_result(msi=4.8, **good)
check(vs["checks"]["decode"]["threshold"] == 24.0 and g1_result(msi=7.0, **good)["g1"] == "no-go",
      "with msi's row for the same model and context the bar is 5x msi's decode (#492's rule)")
check("headroom" not in g1_result(ctx=8192, **{**good, "vram_headroom_bytes": 0.1 * lb.GIB})["checks"],
      "the 768 MiB headroom bar applies at 4096 only, as #492's table says")
partial = g1_result(**{k: v for k, v in good.items() if k != "vram_headroom_bytes"})
check(partial["g1"] == "not_evaluated" and partial["fit"] == "not_evaluated", "without a VRAM reading neither G1 nor the fit passes")
check(g1_result(**{**good, "gpu_offload_ratio": 0.8})["g1"] == "no-go", "a model partly on the CPU is a G1 no-go")
check(g1_result(**{**good, "ttft_warm_p95": 9.0})["g1"] == "pass" and g1_result(**{**good, "ttft_warm_p95": 9.0})["fit"] == "no",
      "the proposed TTFT check fails the fit, not G1")
check(g1_result(warnings=["cache"], **good)["fit"] == "not_evaluated", "a measurement the harness distrusts is never a fit")


def level(n, ttft, tps, wait, errors=0):
    return {"agents": n, "errors": errors, "ttft_p95": ttft, "decode_tps_per_agent_p50": tps, "queue_wait_p95": wait}


check(lb.agent_capacity([level(1, 1, 30, 0), level(2, 2, 25, 1), level(3, 6, 20, 4)], limits) == 2,
      "capacity is the last level inside every threshold")
check(lb.agent_capacity([level(1, 1, 30, 0), level(2, 2, 25, 1, errors=1)], limits) == 1, "a level with errors ends the ramp")
check(lb.agent_capacity([level(1, None, 30, 0)], limits) is None, "an unevaluable first level gives no capacity, not 0")
check(lb.agent_capacity([level(1, 9, 30, 0)], limits) == 0, "a first level outside the thresholds gives 0 agents")
check(lb.within({**level(1, 1, 30, 0), "non_content": 2}, limits) is None, "a level with tool-call turns is not evaluable")

check(lb.agent_turn(4096)[2] == lb.agent_turn(4096)[2], "the agent fixture is byte-identical")

with tempfile.TemporaryDirectory() as tmp:
    run = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "pkgs", "llm-bench", "llm_bench.py"), "mock", "--out", tmp],
                         capture_output=True, text=True, timeout=300, check=False)
    check(run.returncode == 0, f"llm-bench mock runs ({run.stderr[-400:]})")
    results = {os.path.basename(p): lb.load_json(p) for p in glob.glob(os.path.join(tmp, "*.json"))}
    caps = [r for r in results.values() if r["kind"] == "capacity"]
    check(len(caps) == 1 and all("-direct-" in n for n in results), f"mock: one capacity run, the route in its name {sorted(results)}")
    if caps:
        c = caps[0]["capacity"]
        mock_limits = lb.thresholds(os.path.join(ROOT, "pkgs", "llm-bench", "fixtures", "mock-thresholds.json"))
        inside = [lb.within(lv, mock_limits) for lv in c["levels"]]
        n = c["agents"]
        check(isinstance(n, int) and n >= 1 and all(inside[:n]) and (len(inside) == n or inside[n] is False),
              f"mock capacity {n}: every level up to it inside the thresholds, the next one outside ({inside})")
        check(c["queue_wait_source"] == "estimated" and c["levels"][0]["queue_wait_p95"] == 0.0,
              "queue wait is labelled estimated, and zero for one agent")
        check(sum(lv["requests"] for lv in c["levels"]) == len([
            l for p in glob.glob(os.path.join(tmp, "capacity-*.runs.jsonl")) for l in Path(p).read_text().splitlines()]),
              "the unmeasured warm-up is in no level")
    spec = lb.load_json(os.path.join(lb.FIXTURES, "agent-turn.json"))
    for name, r in results.items():
        text = json.dumps(r)
        check("_runs" not in r and not any(x[:40] in text for x in spec["history"] + [spec["task"], spec["system"]]),
              f"{name}: an aggregate, no prompt text")
    runs = [json.loads(l) for p in glob.glob(os.path.join(tmp, "*.runs.jsonl"))
            for l in Path(p).read_text().splitlines() if l.strip()]
    check(runs and not any({"text", "prompt", "response", "content", "id"} & set(r) for r in runs),
          "the private runs file holds timings, no prompt, completion or ID")

with tempfile.TemporaryDirectory() as tmp:
    src = os.path.join(tmp, "src")
    os.mkdir(src)
    for f, tps in (("ollama-qwen25c7.jsonl", 4.8), ("ollama-llama31.jsonl", 4.5)):
        with open(os.path.join(src, f), "w") as fh:
            fh.writelines(json.dumps({"text": "secret completion", "ttft_s": 7.0 + i, "decode_tok_s": tps, "t": 1.0}) + "\n"
                          for i in range(6))
    out = lb.import_msi(src, os.path.join(tmp, "out"), "0" * 40)
    rows = [lb.load_json(p) for p in out]
    check(len(rows) == 2 and all(r["evidence"] == "historical" and r["host"] == "msi-ms7758" and r["ctx"] == 16384 for r in rows),
          "import-msi: one historical msi row per model, at the 16K context it ran")
    check(all(r["metrics"]["decode_tps_p50"]["source"] == "client_measured" and "ttft_warm_p50" not in r["metrics"] for r in rows),
          "import-msi: decode is the archived client's measurement; the mixed-prompt TTFT is not carried over")
    check(sorted(r["metrics"]["decode_tps_p50"]["value"] for r in rows) == [4.5, 4.8]
          and all(r["metrics"]["gpu_offload_ratio"]["value"] is None for r in rows),
          "import-msi: the measured decode rate, and no GPU value for a CPU host")
    check(not any("secret completion" in json.dumps(r) for r in rows), "import-msi: no completion text is carried over")

srv = lb.FakeOllama()
threading.Thread(target=srv.serve_forever, daemon=True).start()
mock_limits = lb.thresholds(os.path.join(ROOT, "pkgs", "llm-bench", "fixtures", "mock-thresholds.json"))


def g1_bench(script, out, host, cold, warm):
    env = {**os.environ, "OLLAMA_URL": srv.base}
    return subprocess.run(["bash", script, host, "mock:7b", "4096", str(cold), str(warm), out], env=env,
                          capture_output=True, text=True, timeout=300, check=False)


def vram_log(path, t0, t1):
    with open(path, "w") as f:
        f.write("timestamp, memory.used [MiB], memory.total [MiB]\n")
        t = t0
        while t <= t1 + 1:
            f.write(f"{time.strftime('%Y/%m/%d %H:%M:%S', time.localtime(t))}.{int(t % 1 * 1000):03d}, 6656 MiB, 8192 MiB\n")
            t += 0.02


try:
    bench = os.path.join(ROOT, "scripts", "ollama-g1-bench.sh")
    with tempfile.TemporaryDirectory() as tmp:
        d = os.path.join(tmp, "g1")
        os.mkdir(d)
        t0 = time.time()
        run = g1_bench(bench, os.path.join(d, "g1-asus.jsonl"), "192.168.10.113", 2, 5)
        check(run.returncode == 0, f"#492's G1 bench runs against the fake ({run.stderr[-300:]})")
        vram_log(os.path.join(d, "vram-asus.csv"), t0, time.time())
        with open(os.path.join(d, "g1-msi.jsonl"), "w") as f:
            f.writelines(json.dumps({"host": "192.168.10.235", "model": "mock:7b", "ctx": 4096, "kind": "warm", "clients": 1,
                                    "decode_tok_s": 20.0, "ttft_s": 9.0, "load_s": 0, "prompt_tokens": 2048, "t_start": 0, "t_end": 1}) + "\n"
                         for _ in range(5))
        out = lb.import_g1(d, os.path.join(tmp, "out"), mock_limits)
        imported = [lb.load_json(p) for p in out]
        rows = {r["host"]: r for r in imported}
        a = rows.get("asus-b460m", {})
        check(set(rows) == {"asus-b460m", "msi-ms7758"} and a.get("samples") == {"warm": 5, "cold": 2},
              f"import-g1: one fit row per host, model and context, named by fleet host, with its sample counts ({sorted(rows)})")
        check(a["warnings"] == [] and a["metrics"]["prompt_tokens"]["value"] == 2048,
              f"the bench's per-run nonce keeps the prompt cache out ({a['warnings']})")
        check(a["checks"]["decode"]["threshold"] == 100.0 and a["g1"] == "pass",
              f"the G1 decode bar is 5x msi's decode for the same model and context ({a['checks'].get('decode')})")
        check(a["metrics"]["vram_headroom_bytes"]["value"] == 1536 * lb.MIB and a["metrics"]["vram_headroom_bytes"]["source"] == "nvidia_smi"
              and a["metrics"]["ttft_warm_p95"]["source"] == "insufficient_samples",
              "VRAM comes from the nvidia-smi log; p95 of 5 warm runs is not reported")
        check(a["fixture"]["name"] == "scripts/ollama-g1-bench.sh" and a["fixture"]["sha256"] and "top_k1" in a["fixture"]["sampling"],
              "the result names #492's fixture and sampling: one contract")
        check(srv.cache_hits == 0, f"no request of the bench repeats the previous prompt: the nonce keeps Ollama's cache out ({srv.cache_hits} hits)")
        # what a cache-served warm phase looks like in the bench's output: few prompt tokens evaluated
        d2 = os.path.join(tmp, "g1-cached")
        os.mkdir(d2)
        with open(os.path.join(d, "g1-asus.jsonl")) as src, open(os.path.join(d2, "g1-asus.jsonl"), "w") as dst:
            for l in src:
                r = json.loads(l)
                if r["kind"] == "warm":
                    r["prompt_tokens"] = 8
                dst.write(json.dumps(r) + "\n")
        shutil.copy(os.path.join(d, "vram-asus.csv"), d2)
        cached = next(lb.load_json(p) for p in lb.import_g1(d2, os.path.join(tmp, "out2"), mock_limits))
        check(any("prompt cache" in w for w in cached["warnings"]) and cached["fit"] != "yes",
              f"warm runs that evaluated a handful of prompt tokens are caught as cache-served, and never a fit ({cached['warnings']})")
    tool = lb.chat_stream(srv.base + "/v1", "mock:tools", lb.agent_turn(4096, "t")[0], [])
    check(tool["kind"] == "tool_call" and tool["ttft_s"] is None and tool["decode_source"] == "whole_turn",
          f"a tool-call turn is classified, with no content TTFT and its decode over the whole turn ({tool})")
    check(lb.chat_stream("http://127.0.0.1:9/v1", "mock:7b", [], [])["error"], "a refused connection is an error row, not an exception")
finally:
    srv.shutdown()

# Pinned Paddock d592a0e routes.rs: /api/server and /v1/models expose runtime bounds, not weight hashes.
paddock_server = {"role": "runner", "version": "0.1.21", "model": "mock:7b", "max_ctx": 4096, "max_batch": 1}
paddock_models = {"data": [{"id": "mock:7b", "owned_by": "paddock", "context_length": 4096}]}
for label, server_patch, listing in [
    ("wrong runner role", {"role": "manager"}, paddock_models),
    ("missing version", {"version": None}, paddock_models),
    ("non-version text", {"version": "private\nprompt"}, paddock_models),
    ("different served model", {"model": "other"}, paddock_models),
    ("missing context", {"max_ctx": None}, paddock_models),
    ("boolean batch", {"max_batch": True}, paddock_models),
    ("contradictory context", {"max_ctx": 8192}, paddock_models),
    ("missing model list", {}, {}),
    ("missing model", {}, {"data": []}),
    ("ambiguous model", {}, {"data": paddock_models["data"] * 2}),
    ("wrong backend", {}, {"data": [{**paddock_models["data"][0], "owned_by": "ollama"}]}),
]:
    with patch.object(lb, "get_json", side_effect=[{**paddock_server, **server_patch}, listing]), \
            patch.object(lb, "chat_stream") as inference:
        try:
            lb.capacity("http://fixture/v1", "fixture", "mock:7b", 4096, "direct", backend="paddock")
        except (ValueError, TypeError):
            check(not inference.called, f"Paddock {label}: refused before inference")
        else:
            check(False, f"Paddock {label}: accepted invalid metadata")


class PaddockHandler(lb.FakeHandler):
    def authorized(self):
        if self.headers.get("Authorization") == "Bearer fixture-key":
            return True
        self.send_error(401)
        return False

    def do_GET(self):
        self.server.probes.append(self.path)
        if not self.authorized():
            return
        ctx = 8192 if self.server.drift and self.server.chats else 4096
        if self.path == "/api/server":
            self.reply({**paddock_server, "max_ctx": ctx})
        elif self.path == "/v1/models":
            self.reply({"data": [{**paddock_models["data"][0], "context_length": ctx}]})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.authorized():
            self.server.chats += 1
            super().do_POST()


paddock = lb.FakeOllama()
paddock.RequestHandlerClass = PaddockHandler
paddock.probes, paddock.chats, paddock.drift = [], 0, False
threading.Thread(target=paddock.serve_forever, daemon=True).start()
try:
    row = lb.capacity(paddock.base + "/v1", "fixture", "mock:7b", 4096, "direct", key="fixture-key",
                      max_n=1, per_level=20, limits=mock_limits, backend="paddock")
    check(row["backend"] == "paddock" and row["backend_version"] == "0.1.21"
          and row["settings"]["context_length_loaded"] == 4096 and row["settings"]["max_batch_loaded"] == 1
          and row["settings"]["num_ctx"] is None, "Paddock authenticated HTTP run records actual runtime bounds")
    check(paddock.probes == ["/api/server", "/v1/models"] * 2 and paddock.chats == 21,
          "Paddock metadata checked before and after; no Ollama API probes; warmup unmeasured")
    check(row["digest"] is None and row["quant"] is None and row["capacity"]["agents"] is None
          and any("not a matched-model comparison" in w for w in row["warnings"]),
          "Paddock unknown weight identity stays unknown and cannot produce a validated capacity")
    check(row["capacity"]["levels"][0]["requests"] == 20 and row["capacity"]["levels"][0]["errors"] == 0,
          "Paddock retains measured streamed timing rows despite unverified weight identity")
    with tempfile.TemporaryDirectory() as tmp:
        original = deepcopy(row)
        paddock_path = lb.write(deepcopy(original), tmp)
        ollama = deepcopy(original)
        del ollama["backend"]
        ollama_path = lb.write(ollama, tmp)
        check(paddock_path != ollama_path and all(os.path.exists(p) for p in (paddock_path, ollama_path)),
              "same-host/model/context Paddock and Ollama artifacts cannot overwrite each other")
        check("fixture-key" not in Path(paddock_path).read_text(), "Paddock auth key never enters the aggregate")
    paddock.drift, paddock.chats = True, 0
    changed = lb.capacity(paddock.base + "/v1", "fixture", "mock:7b", 4096, "direct", key="fixture-key",
                          max_n=1, per_level=1, limits=mock_limits, backend="paddock")
    check(any("changed during measurement" in w for w in changed["warnings"]),
          "Paddock runtime change during a measurement is explicitly rejected")
    with patch.object(lb, "request") as http:
        try:
            lb.capacity(paddock.base + "/v1", "fixture", "mock:7b", 4096, "gateway", backend="paddock")
        except ValueError:
            check(not http.called, "Paddock gateway metadata bypass refused before any request")
        else:
            check(False, "Paddock gateway metadata bypass accepted")
finally:
    paddock.shutdown()
    paddock.server_close()

committed = glob.glob(os.path.join(ROOT, "pkgs", "llm-bench", "scorecard", "*"))
check(committed and all(p.endswith(".json") for p in committed), f"the scorecard holds aggregates only, no runs files {committed}")
for p in committed:
    r = lb.load_json(p)
    check(r.get("schema") == lb.SCHEMA and "_runs" not in r and r["evidence"] in ("measured", "historical"),
          f"{os.path.basename(p)}: an llm-bench/1 aggregate")

print(f"{'FAIL' if failed else 'ok'}: {failed} failed")
sys.exit(1 if failed else 0)
