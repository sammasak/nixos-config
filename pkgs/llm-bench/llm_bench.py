"""llm-bench: the local-inference benchmark of nixos-config#493.

fit       one model on one Ollama host, direct (backend timings): cold starts and warm runs at one context size, GPU
          offload from /api/ps, VRAM and GPU power from black-pi's Prometheus when given
capacity  N = 1, 2, ... concurrent Pi-shaped streamed turns against an OpenAI-compatible base (Ollama's /v1 direct, or
          the gateway with the Pi project key); the agent capacity is the largest N inside every capacity threshold
import-msi  the archived MSI evidence (homelab-gitops colibri-msi results), read and normalised, never edited
mock      the same fit and capacity runs against a built-in deterministic fake Ollama, so the gate runs without hardware
table     the model-fit table (CSV) of result files

Every value carries its source: provider_reported (Ollama's own timings), client_measured, prometheus, estimated or
unavailable. A quantile needs its sample floor or it is insufficient_samples; a missing value stays null, never 0.
Prompts, completions and per-run IDs never leave the private runs file.
"""
import argparse
import csv
import hashlib
import http.server
import json
import math
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

SCHEMA = "llm-bench/1"
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
# p50 needs 5 samples, p95 20: below that the quantile is not reported
FLOOR = {0.5: 5, 0.95: 20}
SETTINGS = {"temperature": 0, "seed": 42, "num_predict": 128}
GIB = 1024 ** 3


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def thresholds(path=None):
    return load_json(path or os.path.join(HERE, "thresholds.json"))


# ---- fixtures ---------------------------------------------------------------------------------------------------

def long_prompt(ctx):
    """The fit prompt for a context size: the fixed corpus, numbered and repeated to ~70% of ctx at ~3.5 chars per
    token, then the fixed question. Deterministic: the same ctx gives the same bytes and sha256."""
    spec = load_json(os.path.join(FIXTURES, "long-context.json"))
    budget = int(ctx * 0.7 * 3.5)
    parts, n = [], 0
    while sum(len(p) for p in parts) < budget:
        parts.append(f"## Section {n}\n{spec['corpus'][n % len(spec['corpus'])]}\n")
        n += 1
    text = "".join(parts)[:budget] + "\n" + spec["question"]
    return text, hashlib.sha256(text.encode()).hexdigest()


def agent_turn(ctx):
    """A Pi-shaped turn: system prompt, tool schemas and history filled to ~60% of ctx, then the task."""
    spec = load_json(os.path.join(FIXTURES, "agent-turn.json"))
    history, n = [], 0
    budget = int(ctx * 0.6 * 3.5)
    while sum(len(m["content"]) for m in history) < budget:
        history.append({"role": "user" if n % 2 == 0 else "assistant", "content": spec["history"][n % len(spec["history"])]})
        n += 1
    messages = [{"role": "system", "content": spec["system"]}] + history + [{"role": "user", "content": spec["task"]}]
    body = json.dumps({"messages": messages, "tools": spec["tools"]}, sort_keys=True)
    return messages, spec["tools"], hashlib.sha256(body.encode()).hexdigest()


# ---- statistics -------------------------------------------------------------------------------------------------

def quantile(xs, q):
    """Nearest-rank quantile, or None below the sample floor."""
    xs = sorted(x for x in xs if x is not None)
    if len(xs) < FLOOR[q]:
        return None
    return xs[max(0, math.ceil(q * len(xs)) - 1)]


def metric(value, unit, source, n=None):
    if value is None:
        source = "insufficient_samples" if n else "unavailable"
    return {"value": value, "unit": unit, "source": source, "n": n}


# ---- HTTP -------------------------------------------------------------------------------------------------------

def request(url, body=None, headers=None, timeout=600):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    return urllib.request.urlopen(req, timeout=timeout)


def get_json(url, timeout=30):
    with request(url, timeout=timeout) as r:
        return json.load(r)


def prom_query(base, expr, at):
    """One instant query; None when Prometheus is not given, unreachable, or has no series (never 0)."""
    if not base:
        return None
    q = urllib.parse.urlencode({"query": expr, "time": f"{at:.3f}"})
    try:
        res = get_json(f"{base}/api/v1/query?{q}")["data"]["result"]
    except (OSError, ValueError, KeyError):
        return None
    return float(res[0]["value"][1]) if res else None


# ---- fit --------------------------------------------------------------------------------------------------------

def generate(base, model, prompt, ctx, keep_alive="5m"):
    """One streamed /api/generate: client TTFT to the first content token, and Ollama's own timings."""
    body = {"model": model, "prompt": prompt, "stream": True, "keep_alive": keep_alive,
            "options": {**SETTINGS, "num_ctx": ctx}}
    t0 = time.monotonic()
    ttft, final = None, {}
    with request(f"{base}/api/generate", body) as r:
        for line in r:
            if not line.strip():
                continue
            chunk = json.loads(line)
            if ttft is None and chunk.get("response"):
                ttft = time.monotonic() - t0
            if chunk.get("done"):
                final = chunk
    total = time.monotonic() - t0
    ns = 1e-9
    eval_s = final.get("eval_duration", 0) * ns
    return {
        "ttft_s": ttft, "total_s": total,
        "load_s": final.get("load_duration", 0) * ns if "load_duration" in final else None,
        "prompt_tokens": final.get("prompt_eval_count"),
        "prompt_eval_s": final.get("prompt_eval_duration", 0) * ns if "prompt_eval_duration" in final else None,
        "decode_tokens": final.get("eval_count"),
        "decode_tps": final["eval_count"] / eval_s if final.get("eval_count") and eval_s > 0 else None,
    }


def unload(base, model, timeout=60):
    with request(f"{base}/api/generate", {"model": model, "keep_alive": 0}):
        pass
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not any(m.get("name") == model or m.get("model") == model for m in get_json(f"{base}/api/ps").get("models", [])):
            return
        time.sleep(0.5)
    raise SystemExit(f"llm-bench: {model} still loaded {timeout}s after keep_alive 0")


def model_identity(base, model):
    tags = get_json(f"{base}/api/tags").get("models", [])
    m = next((t for t in tags if t.get("name") == model or t.get("model") == model), None)
    if m is None:
        return None
    return {"digest": m.get("digest"), "quant": (m.get("details") or {}).get("quantization_level"),
            "parameter_size": (m.get("details") or {}).get("parameter_size"),
            "ollama_version": get_json(f"{base}/api/version").get("version")}


def fit(base, host, model, ctx, cold=5, warm=20, prom=None, limits=None):
    limits = limits or thresholds()
    ident = model_identity(base, model)
    started = time.time()
    if ident is None:
        return result("fit", host, model, ctx, None, started, rejected=f"{model} is not pulled on {host}")
    prompt, sha = long_prompt(ctx)
    runs = []
    for _ in range(cold):
        unload(base, model)
        runs.append({"start": "cold", **generate(base, model, prompt, ctx)})
    loaded_at = time.time()
    ps = next((m for m in get_json(f"{base}/api/ps").get("models", []) if model in (m.get("name"), m.get("model"))), {})
    for _ in range(warm):
        runs.append({"start": "warm", **generate(base, model, prompt, ctx)})
    finished = time.time()
    w = [r for r in runs if r["start"] == "warm"]
    c = [r for r in runs if r["start"] == "cold"]
    node = f'node="{host}"'
    load_window = max(1, int(loaded_at - started))
    warm_window = max(1, int(finished - loaded_at))
    total = prom_query(prom, f"max(nvidia_smi_memory_total_bytes{{{node}}})", finished)
    vram_load = prom_query(prom, f"max(max_over_time(nvidia_smi_memory_used_bytes{{{node}}}[{load_window}s]))", loaded_at)
    vram_steady = prom_query(prom, f"max(max_over_time(nvidia_smi_memory_used_bytes{{{node}}}[{warm_window}s]))", finished)
    power = prom_query(prom, f"avg(avg_over_time(nvidia_smi_power_draw_watts{{{node}}}[{warm_window}s]))", finished)
    out_tokens = sum(r["decode_tokens"] or 0 for r in w)
    offload = ps["size_vram"] / ps["size"] if ps.get("size") else None
    metrics = {
        "decode_tps_p50": metric(quantile([r["decode_tps"] for r in w], 0.5), "tokens/s", "provider_reported", len(w)),
        "ttft_warm_p50": metric(quantile([r["ttft_s"] for r in w], 0.5), "s", "client_measured", len(w)),
        "ttft_warm_p95": metric(quantile([r["ttft_s"] for r in w], 0.95), "s", "client_measured", len(w)),
        "ttft_cold_p50": metric(quantile([r["ttft_s"] for r in c], 0.5), "s", "client_measured", len(c)),
        "cold_load_p50": metric(quantile([r["load_s"] for r in c], 0.5), "s", "provider_reported", len(c)),
        "prompt_tokens": metric(w[0]["prompt_tokens"] if w else None, "tokens", "provider_reported"),
        "gpu_offload_ratio": metric(offload, "ratio", "provider_reported"),
        "vram_load_bytes": metric(vram_load, "bytes", "prometheus"),
        "vram_steady_bytes": metric(vram_steady, "bytes", "prometheus"),
        "vram_headroom_bytes": metric(total - vram_steady if None not in (total, vram_steady) else None, "bytes", "prometheus"),
        # GPU-estimated: the board's own power reading, not the host's
        "gpu_joules_per_output_token": metric(power * warm_window / out_tokens if power and out_tokens else None,
                                              "J/token", "estimated"),
    }
    r = result("fit", host, model, ctx, ident, started, metrics=metrics,
               fixture={"name": "long-context", "sha256": sha, "chars": len(prompt)},
               samples={"warm": len(w), "cold": len(c)}, runs=runs)
    return judge_fit(r, limits)


def judge_fit(r, limits):
    m, t = r["metrics"], limits["fit"]
    big = r["model"] == t["decode_tps_min_model"]
    checks = {
        "headroom": (m["vram_headroom_bytes"]["value"], t["vram_headroom_gib_min"] * GIB, ">="),
        "offload": (m["gpu_offload_ratio"]["value"], t["gpu_offload_ratio_min"], ">="),
        "decode": (m["decode_tps_p50"]["value"], t["decode_tps_min"] if big else t["decode_tps_min_other"], ">="),
        "ttft": (m["ttft_warm_p95"]["value"], t["ttft_warm_p95_s_max"][str(r["ctx"])], "<="),
        "cold_load": (m["cold_load_p50"]["value"], t["cold_load_s_max"], "<="),
    }
    r["checks"] = {k: {"pass": None if v is None else (v >= lim if op == ">=" else v <= lim), "value": v, "threshold": lim, "op": op}
                   for k, (v, lim, op) in checks.items()}
    passes = [c["pass"] for c in r["checks"].values()]
    r["fit"] = "no" if False in passes else ("yes" if None not in passes else "not_evaluated")
    return r


# ---- capacity ---------------------------------------------------------------------------------------------------

def chat_stream(base, model, messages, tools, key=None):
    """One streamed /v1/chat/completions turn: TTFT to the first content or tool-call delta, decode rate after it."""
    body = {"model": model, "messages": messages, "tools": tools, "stream": True,
            "stream_options": {"include_usage": True}, "temperature": 0, "seed": 42, "max_tokens": SETTINGS["num_predict"]}
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    t0 = time.monotonic()
    ttft, chunks, usage, err = None, 0, None, None
    try:
        with request(f"{base}/chat/completions", body, headers) as r:
            for line in r:
                line = line.strip()
                if not line.startswith(b"data:") or line == b"data: [DONE]":
                    continue
                d = json.loads(line[5:])
                usage = d.get("usage") or usage
                for ch in d.get("choices", []):
                    delta = ch.get("delta") or {}
                    if delta.get("content") or delta.get("tool_calls"):
                        chunks += 1
                        if ttft is None:
                            ttft = time.monotonic() - t0
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as e:
        err = getattr(e, "code", None) or type(e).__name__
    total = time.monotonic() - t0
    tokens = (usage or {}).get("completion_tokens")
    gen = total - ttft if ttft is not None else None
    return {"ttft_s": ttft, "total_s": total, "error": err,
            "decode_tokens": tokens if tokens is not None else chunks,
            "tokens_source": "provider_reported" if tokens is not None else "estimated",
            "decode_tps": (tokens if tokens is not None else chunks) / gen if gen and gen > 0 else None}


def capacity_level(rows, baseline_ttft, n):
    ttft = [r["ttft_s"] for r in rows]
    return {
        "agents": n, "requests": len(rows), "errors": sum(1 for r in rows if r["error"] or r["ttft_s"] is None),
        "ttft_p50": quantile(ttft, 0.5), "ttft_p95": quantile(ttft, 0.95),
        "decode_tps_per_agent_p50": quantile([r["decode_tps"] for r in rows], 0.5),
        # estimated: the gateway reports no queue wait; this is the TTFT above the single-agent median
        "queue_wait_p95": None if quantile(ttft, 0.95) is None or baseline_ttft is None
        else max(0.0, quantile(ttft, 0.95) - baseline_ttft),
    }


def within(level, limits):
    """Is one concurrency level inside every capacity threshold? None when a value is missing."""
    t = limits["capacity"]
    vals = (level["ttft_p95"], level["decode_tps_per_agent_p50"], level["queue_wait_p95"])
    if level["errors"] or None in vals:
        return None if not level["errors"] else False
    return vals[0] <= t["ttft_p95_s_max"] and vals[1] >= t["decode_tps_per_agent_min"] and vals[2] <= t["queue_wait_p95_s_max"]


def agent_capacity(levels, limits):
    """The largest N with every level up to it inside the thresholds; None when N=1 was not evaluable."""
    best = 0
    for lv in sorted(levels, key=lambda x: x["agents"]):
        ok = within(lv, limits)
        if ok is None:
            return None if best == 0 else best
        if not ok:
            break
        best = lv["agents"]
    return best


def capacity(base, host, model, ctx, route, key=None, max_n=8, per_level=20, limits=None):
    limits = limits or thresholds()
    messages, tools, sha = agent_turn(ctx)
    started = time.time()
    levels, runs, baseline = [], [], None
    for n in range(1, max_n + 1):
        rows = []
        lock = threading.Lock()

        def agent():
            for _ in range(math.ceil(per_level / n)):
                r = chat_stream(base, model, messages, tools, key)
                with lock:
                    rows.append(r)

        threads = [threading.Thread(target=agent) for _ in range(n)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        runs += [{"agents": n, **r} for r in rows]
        if n == 1:
            baseline = quantile([r["ttft_s"] for r in rows], 0.5)
        lv = capacity_level(rows, baseline, n)
        levels.append(lv)
        if within(lv, limits) is not True:
            break
    agents = agent_capacity(levels, limits)
    # direct: the Ollama behind /v1 names the model; through the gateway the backend is the gateway's choice
    ident = model_identity(base.removesuffix("/v1"), model) if route == "direct" else None
    r = result("capacity", host, model, ctx, ident, started,
               fixture={"name": "agent-turn", "sha256": sha}, route=route, runs=runs,
               samples={"per_level": per_level, "levels": len(levels)})
    r["capacity"] = {"agents": agents, "levels": levels, "queue_wait_source": "estimated"}
    return r


# ---- results ----------------------------------------------------------------------------------------------------

def result(kind, host, model, ctx, ident, started, metrics=None, fixture=None, samples=None, runs=None, route="direct",
           rejected=None, evidence="measured"):
    ident = ident or {}
    return {
        "schema": SCHEMA, "kind": kind, "evidence": evidence, "host": host, "model": model,
        "quant": ident.get("quant"), "digest": ident.get("digest"), "ollama_version": ident.get("ollama_version"),
        "ctx": ctx, "route": route, "settings": {**SETTINGS, "num_ctx": ctx}, "fixture": fixture, "samples": samples,
        "metrics": metrics or {}, "checks": {}, "fit": (("no" if rejected else "not_evaluated") if kind == "fit" else None),
        "rejected": rejected,
        "started_at": started, "finished_at": time.time(), "_runs": runs or [],
    }


def write(r, out):
    os.makedirs(out, exist_ok=True)
    name = f"{r['kind']}-{r['host']}-{r['model'].replace(':', '_').replace('/', '_')}-{r['ctx']}"
    runs = r.pop("_runs", [])
    with open(os.path.join(out, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(r, f, indent=1, sort_keys=True)
        f.write("\n")
    # private: per-run timings, never committed with the aggregate or read by the rules
    with open(os.path.join(out, name + ".runs.jsonl"), "w", encoding="utf-8") as f:
        for run in runs:
            f.write(json.dumps(run, sort_keys=True) + "\n")
    return os.path.join(out, name + ".json")


TABLE = ["host", "model", "quant", "ctx", "evidence", "vram_load_gib", "vram_steady_gib", "headroom_gib", "gpu_offload",
         "decode_tps_p50", "ttft_warm_p50_s", "ttft_warm_p95_s", "ttft_cold_p50_s", "cold_load_s", "agent_capacity",
         "fit", "failed_checks"]


def table_row(r):
    m = {k: (v or {}).get("value") for k, v in r.get("metrics", {}).items()}
    gib = lambda b: None if b is None else round(b / GIB, 2)
    rnd = lambda x, n=2: None if x is None else round(x, n)
    return {
        "host": r["host"], "model": r["model"], "quant": r["quant"], "ctx": r["ctx"], "evidence": r["evidence"],
        "vram_load_gib": gib(m.get("vram_load_bytes")), "vram_steady_gib": gib(m.get("vram_steady_bytes")),
        "headroom_gib": gib(m.get("vram_headroom_bytes")), "gpu_offload": rnd(m.get("gpu_offload_ratio")),
        "decode_tps_p50": rnd(m.get("decode_tps_p50"), 1), "ttft_warm_p50_s": rnd(m.get("ttft_warm_p50")),
        "ttft_warm_p95_s": rnd(m.get("ttft_warm_p95")), "ttft_cold_p50_s": rnd(m.get("ttft_cold_p50")),
        "cold_load_s": rnd(m.get("cold_load_p50")), "agent_capacity": (r.get("capacity") or {}).get("agents"),
        "fit": r["fit"], "failed_checks": " ".join(k for k, c in r.get("checks", {}).items() if c["pass"] is False),
    }


# ---- historical MSI ---------------------------------------------------------------------------------------------

def import_msi(src, out, commit):
    """homelab-gitops colibri-msi results at `commit`, Ollama on msi's CPU: one historical row per model, all its
    prompts under 4K tokens. homelab-gitops is private, so this reads a checkout and only the aggregate is committed."""
    written = []
    for fname, model in (("ollama-qwen25c7.jsonl", "qwen2.5-coder:7b"), ("ollama-llama31.jsonl", "llama3.1:8b")):
        rows = [json.loads(l) for l in open(os.path.join(src, fname), encoding="utf-8") if l.strip()]
        r = result("fit", "msi-ms7758", model, 4096, {"quant": "Q4_K_M"}, rows[0]["t"] if rows else 0, evidence="historical",
                   fixture={"name": f"homelab-gitops@{commit} docs/decisions/assets/colibri-msi/results/{fname}",
                            "sha256": hashlib.sha256(open(os.path.join(src, fname), "rb").read()).hexdigest()},
                   samples={"warm": len(rows), "cold": 0})
        r["metrics"] = {
            "decode_tps_p50": metric(quantile([x.get("decode_tok_s") for x in rows], 0.5), "tokens/s", "provider_reported", len(rows)),
            "ttft_warm_p50": metric(quantile([x.get("ttft_s") for x in rows], 0.5), "s", "client_measured", len(rows)),
            # CPU-only: no GPU, so the GPU fields stay unavailable rather than 0
            "gpu_offload_ratio": metric(None, "ratio", "unavailable"),
        }
        r["fit"] = "not_evaluated"
        written.append(write(r, out))
    return written


# ---- mock -------------------------------------------------------------------------------------------------------

class FakeOllama(http.server.ThreadingHTTPServer):
    """Ollama's API with one request at a time (OLLAMA_NUM_PARALLEL=1) and fixed per-token costs."""
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FakeHandler)
        self.loaded = None
        self.gate = threading.Lock()
        self.base = f"http://127.0.0.1:{self.server_address[1]}"


class FakeHandler(http.server.BaseHTTPRequestHandler):
    MODEL, LOAD_S, PREFILL_S, TOKEN_S, TOKENS = "mock:7b", 0.05, 0.02, 0.002, 32

    def log_message(self, *a):
        pass

    def reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        s = self.server
        if self.path == "/api/tags":
            self.reply({"models": [{"name": self.MODEL, "digest": "sha256:" + "0" * 64,
                                    "details": {"quantization_level": "Q4_K_M", "parameter_size": "7B"}}]})
        elif self.path == "/api/ps":
            self.reply({"models": [] if s.loaded is None else [{"name": s.loaded, "size": 6 * GIB, "size_vram": 6 * GIB}]})
        elif self.path == "/api/version":
            self.reply({"version": "0.0.0-mock"})
        elif self.path.startswith("/api/v1/query?"):
            # black-pi's Prometheus for the GPU series: a fixed 8 GiB board, 6.5 GiB used, 150 W
            expr = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)["query"][0]
            value = next((v for k, v in (("memory_total", 8 * GIB), ("memory_used", 6.5 * GIB), ("power_draw", 150.0))
                          if k in expr), None)
            self.reply({"status": "success", "data": {"resultType": "vector",
                        "result": [] if value is None else [{"metric": {}, "value": [0, str(value)]}]}})
        else:
            self.send_error(404)

    def stream(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for c in chunks:
            self.wfile.write(c)
            self.wfile.flush()

    def do_POST(self):
        s = self.server
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body.get("keep_alive") == 0 and "prompt" not in body:
            s.loaded = None
            return self.reply({"done": True})
        with s.gate:
            load = 0.0
            if s.loaded != body["model"]:
                load = self.LOAD_S
                time.sleep(load)
                s.loaded = body["model"]
            time.sleep(self.PREFILL_S)
            if self.path == "/api/generate":
                def gen():
                    for i in range(self.TOKENS):
                        time.sleep(self.TOKEN_S)
                        yield json.dumps({"response": "x", "done": False}).encode() + b"\n"
                    yield json.dumps({"done": True, "load_duration": int(load * 1e9), "prompt_eval_count": 2048,
                                      "prompt_eval_duration": int(self.PREFILL_S * 1e9), "eval_count": self.TOKENS,
                                      "eval_duration": int(self.TOKENS * self.TOKEN_S * 1e9)}).encode() + b"\n"
                self.stream(gen())
            elif self.path == "/v1/chat/completions":
                def sse():
                    for i in range(self.TOKENS):
                        time.sleep(self.TOKEN_S)
                        yield b"data: " + json.dumps({"choices": [{"delta": {"content": "x"}}]}).encode() + b"\n\n"
                    yield b"data: " + json.dumps({"choices": [], "usage": {"completion_tokens": self.TOKENS}}).encode() + b"\n\n"
                    yield b"data: [DONE]\n\n"
                self.stream(sse())
            else:
                self.send_error(404)


def mock(out, limits_path=None):
    srv = FakeOllama()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    limits = thresholds(limits_path or os.path.join(FIXTURES, "mock-thresholds.json"))
    try:
        paths = [write(fit(srv.base, "mock-host", FakeHandler.MODEL, ctx, cold=5, warm=20, prom=srv.base, limits=limits), out)
                 for ctx in (4096, 8192)]
        paths.append(write(capacity(srv.base + "/v1", "mock-host", FakeHandler.MODEL, 4096, "direct", max_n=6,
                                    per_level=20, limits=limits), out))
    finally:
        srv.shutdown()
    return paths


# ---- CLI --------------------------------------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog="llm-bench", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fit")
    f.add_argument("--base", required=True, help="Ollama, e.g. http://192.168.10.113:11434")
    f.add_argument("--host", required=True)
    f.add_argument("--model", required=True)
    f.add_argument("--ctx", type=int, choices=(4096, 8192), required=True)
    f.add_argument("--cold", type=int, default=5)
    f.add_argument("--warm", type=int, default=20)
    f.add_argument("--prometheus", help="black-pi Prometheus, e.g. http://192.168.10.137:9090")
    f.add_argument("--out", required=True)
    c = sub.add_parser("capacity")
    c.add_argument("--base", required=True, help="OpenAI-compatible base: Ollama's /v1 or the gateway's /v1")
    c.add_argument("--host", required=True)
    c.add_argument("--model", required=True)
    c.add_argument("--ctx", type=int, choices=(4096, 8192), default=4096)
    c.add_argument("--route", choices=("direct", "gateway"), required=True)
    c.add_argument("--key-file", help="the Pi project key, for --route gateway")
    c.add_argument("--max-agents", type=int, default=8)
    c.add_argument("--per-level", type=int, default=20)
    c.add_argument("--out", required=True)
    i = sub.add_parser("import-msi")
    i.add_argument("--src", required=True, help="a homelab-gitops checkout's docs/decisions/assets/colibri-msi/results")
    i.add_argument("--commit", required=True, help="the homelab-gitops commit of that checkout")
    i.add_argument("--out", required=True)
    m = sub.add_parser("mock")
    m.add_argument("--out", required=True)
    t = sub.add_parser("table")
    t.add_argument("results", nargs="+")
    a = p.parse_args(argv)
    if a.cmd == "fit":
        print(write(fit(a.base, a.host, a.model, a.ctx, a.cold, a.warm, a.prometheus), a.out))
    elif a.cmd == "capacity":
        key = open(a.key_file, encoding="utf-8").read().strip() if a.key_file else None
        print(write(capacity(a.base, a.host, a.model, a.ctx, a.route, key, a.max_agents, a.per_level), a.out))
    elif a.cmd == "import-msi":
        print("\n".join(import_msi(a.src, a.out, a.commit)))
    elif a.cmd == "mock":
        print("\n".join(mock(a.out)))
    else:
        w = csv.DictWriter(sys.stdout, TABLE)
        w.writeheader()
        for path in a.results:
            w.writerow(table_row(load_json(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
