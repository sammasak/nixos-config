"""llm-bench: the local-inference scorecard of nixos-config#493.

import-g1   the G1 bench of #492 (scripts/ollama-g1-bench.sh, its nvidia-smi vram-*.csv) as llm-bench/1 fit results:
            the one fixture, sampling and G1 rule (scripts/ollama-g1-table.py), here carried into the scorecard with
            each value's source and the proposed TTFT and cold-load checks on top
capacity    N = 1, 2, ... concurrent Pi-shaped streamed turns against an OpenAI-compatible base (Ollama's /v1 direct, or
            the gateway with the Pi project key); the agent capacity is the largest N inside every capacity threshold
import-msi  the archived MSI evidence (homelab-gitops colibri-msi results), read and normalised, never edited
mock        the capacity run against a built-in deterministic fake Ollama, so the gate runs without hardware
table       the model-fit table (CSV) of result files

Every value carries its source: provider_reported (Ollama's own timings), client_measured, nvidia_smi, estimated or
unavailable. A quantile needs its sample floor or it is insufficient_samples; a missing value stays null, never 0.
Prompts, completions and per-run IDs never leave the private runs file.
"""
import argparse
import csv
import datetime
import glob
import hashlib
import http.server
import json
import math
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

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

def agent_turn(ctx, nonce=None):
    """A Pi-shaped turn: system prompt, tool schemas and history filled to ~60% of ctx, then the task. The nonce
    opens the history: agents share the system prompt and tools, as Pi agents do, but not their conversations."""
    spec = load_json(os.path.join(FIXTURES, "agent-turn.json"))
    history, n = [], 0
    budget = int(ctx * 0.6 * 3.5)
    while sum(len(m["content"]) for m in history) < budget:
        history.append({"role": "user" if n % 2 == 0 else "assistant", "content": spec["history"][n % len(spec["history"])]})
        n += 1
    messages = [{"role": "system", "content": spec["system"]}] + history + [{"role": "user", "content": spec["task"]}]
    sha = hashlib.sha256(json.dumps({"messages": messages, "tools": spec["tools"]}, sort_keys=True).encode()).hexdigest()
    if nonce is not None:
        messages[1] = {**messages[1], "content": f"Conversation {nonce}.\n{messages[1]['content']}"}
    return messages, spec["tools"], sha


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


def get_json(url, timeout=30, headers=None):
    with request(url, headers=headers, timeout=timeout) as r:
        return json.load(r)


# ---- G1 import ---------------------------------------------------------------------------------------------------

def loaded(base, model):
    return next((m for m in get_json(f"{base}/api/ps").get("models", []) if model in (m.get("name"), m.get("model"))), None)


def model_identity(base, model):
    tags = get_json(f"{base}/api/tags").get("models", [])
    m = next((t for t in tags if t.get("name") == model or t.get("model") == model), None)
    if m is None:
        return None
    return {"digest": m.get("digest"), "quant": (m.get("details") or {}).get("quantization_level"),
            "parameter_size": (m.get("details") or {}).get("parameter_size"),
            "ollama_version": get_json(f"{base}/api/version").get("version")}


def paddock_metadata(base, model, key=None):
    """Runtime bounds, not weight identity: the runner API does not publish a GGUF digest or quant."""
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    server = get_json(f"{base}/api/server", headers=headers)
    listing = get_json(f"{base}/v1/models", headers=headers)
    if not isinstance(server, dict) or not isinstance(listing, dict):
        raise TypeError("Paddock metadata must be JSON objects")
    version = server.get("version")
    if (server.get("role") != "runner" or not isinstance(version, str) or not 0 < len(version) <= 128
            or not all(c.isascii() and (c.isalnum() or c in ".+-_") for c in version)):
        raise ValueError("Paddock runner identity is missing or invalid")
    ctx, batch = server.get("max_ctx"), server.get("max_batch")
    if type(ctx) is not int or ctx <= 0 or type(batch) is not int or batch <= 0:
        raise TypeError("Paddock loaded context and batch must be positive integers")
    models = listing.get("data")
    if not isinstance(models, list):
        raise TypeError("Paddock model listing is missing")
    matches = [m for m in models if isinstance(m, dict) and m.get("id") == model]
    if (server.get("model") != model or len(matches) != 1 or matches[0].get("owned_by") != "paddock"
            or type(matches[0].get("context_length")) is not int or matches[0]["context_length"] != ctx):
        raise ValueError("Paddock served model or loaded context disagrees with the requested model")
    return {"version": version, "context_length": ctx, "max_batch": batch}


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    return xs[len(xs) // 2] if xs else None


# the fleet's addresses (modules/core/fleet.nix): the G1 bench records the host it was pointed at
FLEET = {"192.168.10.113": "asus-b460m", "192.168.10.235": "msi-ms7758", "192.168.10.110": "acer-swift"}
MIB = 1024 ** 2


def vram_samples(d):
    """nvidia-smi --query-gpu=timestamp,memory.used,memory.total --format=csv -lms 1000, as the G1 procedure logs it."""
    out = []
    for path in sorted(glob.glob(os.path.join(d, "vram-*.csv"))):
        with open(path, encoding="utf-8") as f:
            for row in csv.DictReader(f, skipinitialspace=True):
                ts = datetime.datetime.strptime(row["timestamp"], "%Y/%m/%d %H:%M:%S.%f").astimezone().timestamp()
                out.append((ts, int(row["memory.used [MiB]"].split()[0]) * MIB, int(row["memory.total [MiB]"].split()[0]) * MIB))
    return out


def judge_g1(r, msi_decode, limits):
    """scripts/ollama-g1-table.py's G1 rule, unchanged, plus the proposed TTFT and cold-load checks. G1: headroom at
    4096 at least 768 MiB, every layer on the GPU, decode p50 at least 5x msi's for the same model and context (24
    tok/s when msi has no such row). fit is yes only with every check passing and no warning."""
    m, g, t = r["metrics"], limits["g1"], limits["proposed"]
    need = g["decode_vs_msi"] * msi_decode if msi_decode else g["decode_tps_min"]
    checks = {
        "headroom": (m["vram_headroom_bytes"]["value"], g["headroom_mib_min_at_4096"] * MIB, ">=") if r["ctx"] == 4096 else None,
        "offload": (m["gpu_offload_ratio"]["value"], g["gpu_share_min"], ">="),
        "decode": (m["decode_tps_p50"]["value"], need, ">="),
        "ttft": (m["ttft_warm_p95"]["value"], t["ttft_warm_p95_s_max"][str(r["ctx"])], "<="),
        "cold_load": (m["cold_load_p50"]["value"], t["cold_load_s_max"], "<="),
    }
    r["checks"] = {k: {"pass": None if v is None else (v >= lim if op == ">=" else v <= lim), "value": v, "threshold": lim, "op": op}
                   for k, c in checks.items() if c is not None for v, lim, op in [c]}
    g1 = [r["checks"][k]["pass"] for k in ("headroom", "offload", "decode") if k in r["checks"]]
    r["g1"] = "no-go" if False in g1 else ("pass" if None not in g1 else "not_evaluated")
    passes = [c["pass"] for c in r["checks"].values()]
    r["fit"] = "no" if False in passes else ("yes" if None not in passes and not r["warnings"] else "not_evaluated")
    return r


def import_g1(d, out, limits=None):
    """One fit result per GPU host, model and context from a G1 results directory: g1-*.jsonl (one-client runs; the
    multi-client rows are queueing context, the agent capacity is `capacity`'s) and the vram-*.csv logged meanwhile."""
    limits = limits or thresholds()
    runs = [json.loads(l) for p in sorted(glob.glob(os.path.join(d, "g1-*.jsonl")))
            for l in Path(p).read_text(encoding="utf-8").splitlines() if l.strip()]
    smi = vram_samples(d)
    groups = {}
    for r in runs:
        if r.get("clients", 1) == 1 and r["kind"] in ("cold", "warm"):
            groups.setdefault((FLEET.get(r["host"], r["host"]), r["model"], r["ctx"]), []).append(r)
    msi = {(m, c): quantile([r["decode_tok_s"] for r in rs if r["kind"] == "warm"], 0.5)
           for (h, m, c), rs in groups.items() if h == "msi-ms7758"}
    written = []
    for (host, model, ctx), rs in sorted(groups.items()):
        cold = [r for r in rs if r["kind"] == "cold"]
        warm = [r for r in rs if r["kind"] == "warm"]
        during = lambda xs: [s for s in smi if any(x["t_start"] <= s[0] <= x["t_end"] for x in xs)]
        vc, vw = during(cold), during(warm)
        shares = [r["gpu_share"] for r in rs if r.get("gpu_share") is not None]
        warnings = []
        pc, pw = median(r["prompt_tokens"] for r in cold), median(r["prompt_tokens"] for r in warm)
        if pc and pw is not None and pw < 0.5 * pc:
            warnings.append(f"warm runs evaluated {pw} prompt tokens against {pc} cold: a prompt cache served them")
        gpu = host != "msi-ms7758"
        metrics = {
            "decode_tps_p50": metric(quantile([r["decode_tok_s"] for r in warm], 0.5), "tokens/s", "provider_reported", len(warm)),
            # Ollama's load + prompt eval, as the G1 bench defines TTFT; queue wait is not in it
            "ttft_warm_p50": metric(quantile([r["ttft_s"] for r in warm], 0.5), "s", "provider_reported", len(warm)),
            "ttft_warm_p95": metric(quantile([r["ttft_s"] for r in warm], 0.95), "s", "provider_reported", len(warm)),
            "ttft_cold_p50": metric(quantile([r["ttft_s"] for r in cold], 0.5), "s", "provider_reported", len(cold)),
            "cold_load_p50": metric(quantile([r["load_s"] for r in cold], 0.5), "s", "provider_reported", len(cold)),
            "prompt_tokens": metric(pc, "tokens", "provider_reported", len(cold)),
            "gpu_offload_ratio": metric(min(shares) if shares else None, "ratio", "provider_reported"),
            "vram_load_bytes": metric(max((s[1] for s in vc), default=None) if gpu else None, "bytes", "nvidia_smi"),
            "vram_steady_bytes": metric(statistics.median(s[1] for s in vw) if gpu and vw else None, "bytes", "nvidia_smi"),
            "vram_headroom_bytes": metric(vw[0][2] - max(s[1] for s in vw) if gpu and vw else None, "bytes", "nvidia_smi"),
        }
        first = rs[0]
        r = result("fit", host, model, ctx, {"digest": first.get("digest"), "quant": first.get("quant")}, first["t_start"],
                   metrics=metrics, samples={"warm": len(warm), "cold": len(cold)},
                   fixture={"name": "scripts/ollama-g1-bench.sh", "sha256": first.get("prompt_sha256"),
                            "sampling": first.get("sampling")})
        r["warnings"] = warnings
        written.append(write(judge_g1(r, msi.get((model, ctx)), limits) if gpu else r, out))
    return written


# ---- capacity ---------------------------------------------------------------------------------------------------

def chat_stream(base, model, messages, tools, key=None):
    """One streamed /v1/chat/completions turn. The fixture asks for a text answer (tool_choice none): TTFT is to the
    first content token and decode is over the content after it. A turn that still answers with a tool call (sent as
    one delta at the end) or with reasoning only is kept with its kind, its decode taken over the whole turn."""
    body = {"model": model, "messages": messages, "tools": tools, "tool_choice": "none", "stream": True,
            "stream_options": {"include_usage": True}, "temperature": 0, "seed": 42, "max_tokens": SETTINGS["num_predict"]}
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    t0 = time.monotonic()
    ttft, first_any, chunks, usage, err, kind, reasoned = None, None, 0, None, None, None, False
    try:
        with request(f"{base}/chat/completions", body, headers) as r:
            for line in r:
                line = line.strip()
                if not line.startswith(b"data:") or line == b"data: [DONE]":
                    continue
                d = json.loads(line[5:])
                if d.get("error"):
                    raise RuntimeError(str(d["error"])[:200])
                usage = d.get("usage") or usage
                for ch in d.get("choices", []):
                    delta = ch.get("delta") or {}
                    now = time.monotonic() - t0
                    if delta.get("content"):
                        chunks += 1
                        kind = "content"
                        ttft = now if ttft is None else ttft
                    elif delta.get("tool_calls"):
                        kind = kind or "tool_call"
                    elif delta.get("reasoning") or delta.get("reasoning_content"):
                        kind = kind or "reasoning_only"
                        reasoned = True
                    if first_any is None and kind:
                        first_any = now
    except (OSError, ValueError, RuntimeError) as e:
        err = (getattr(e, "code", None) and f"HTTP {e.code}") or f"{type(e).__name__}: {e}"[:200]
    total = time.monotonic() - t0
    tokens = (usage or {}).get("completion_tokens")
    n = tokens if tokens is not None else chunks
    # completion_tokens counts reasoning too: after reasoning, only the whole turn's rate is honest
    if kind == "content" and not reasoned and ttft is not None and total > ttft and n > 1:
        tps, tps_source = (n - 1) / (total - ttft), "after_first_token"
    else:
        tps, tps_source = (n / total if n and total > 0 else None), "whole_turn"
    return {"ttft_s": ttft if kind == "content" else None, "first_output_s": first_any, "total_s": total, "error": err,
            "kind": kind, "decode_tokens": n, "prompt_tokens": (usage or {}).get("prompt_tokens"),
            "tokens_source": "provider_reported" if tokens is not None else "estimated",
            "decode_tps": tps, "decode_source": tps_source}


def capacity_level(rows, baseline_p95, n):
    ttft = [r["ttft_s"] for r in rows]
    p95 = quantile(ttft, 0.95)
    return {
        "agents": n, "requests": len(rows), "errors": sum(1 for r in rows if r["error"]),
        "non_content": sum(1 for r in rows if not r["error"] and r["kind"] != "content"),
        "ttft_p50": quantile(ttft, 0.5), "ttft_p95": p95,
        "decode_tps_per_agent_p50": quantile([r["decode_tps"] for r in rows], 0.5),
        # estimated: the gateway reports no queue wait; this is the TTFT p95 above the single agent's
        "queue_wait_p95": None if p95 is None or baseline_p95 is None else max(0.0, p95 - baseline_p95),
    }


def within(level, limits):
    """Is one concurrency level inside every capacity threshold? False on any error; None when a value is missing."""
    t = limits["capacity"]
    if level["errors"]:
        return False
    # a tool-call or reasoning-only turn has no content TTFT: the level's TTFT would be over the rest only
    if level.get("non_content"):
        return None
    vals = (level["ttft_p95"], level["decode_tps_per_agent_p50"], level["queue_wait_p95"])
    if None in vals:
        return None
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


def capacity(base, host, model, ctx, route, key=None, max_n=8, per_level=20, limits=None, backend="ollama"):
    if backend not in ("ollama", "paddock") or (backend == "paddock" and route != "direct"):
        raise ValueError("Paddock metadata requires --route direct; gateway backend identity is unknown")
    limits = limits or thresholds()
    _, tools, sha = agent_turn(ctx)
    started = time.time()
    root = base.removesuffix("/v1")
    # Refuse an unverified endpoint before sending any inference traffic.
    paddock = paddock_metadata(root, model, key) if backend == "paddock" else None
    # unmeasured: a cold load or a context reload would otherwise land in N=1 and in the baseline
    warmup = chat_stream(base, model, agent_turn(ctx, "warmup")[0], tools, key)
    resident = paddock if paddock is not None else ((loaded(root, model) or {}) if route == "direct" else {})
    levels, runs, baseline = [], [], None
    for n in range(1, max_n + 1):
        rows = []
        lock = threading.Lock()

        def agent(a, n=n, rows=rows, lock=lock):
            for i in range(math.ceil(per_level / n)):
                r = chat_stream(base, model, agent_turn(ctx, f"{n}-{a}-{i}")[0], tools, key)
                with lock:
                    rows.append(r)

        threads = [threading.Thread(target=agent, args=(a,)) for a in range(n)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        runs += [{"agents": n, **r} for r in rows]
        if n == 1:
            baseline = quantile([r["ttft_s"] for r in rows], 0.95)
        lv = capacity_level(rows, baseline, n)
        levels.append(lv)
        if within(lv, limits) is not True:
            break
    agents = agent_capacity(levels, limits)
    # direct: the Ollama behind /v1 names the model; through the gateway the backend is the gateway's choice
    ident = model_identity(root, model) if route == "direct" and backend == "ollama" else None
    r = result("capacity", host, model, ctx, ident, started,
               fixture={"name": "agent-turn", "sha256": sha, "nonce": "Conversation <n>-<agent>-<i>. history prefix"},
               route=route, runs=runs, samples={"per_level": per_level, "levels": len(levels)})
    # /v1 takes no num_ctx: the context is what the server loaded, observed, not what --ctx asked for
    r["settings"]["num_ctx"] = None
    r["settings"]["context_length_loaded"] = resident.get("context_length")
    prompt_tokens = median(x.get("prompt_tokens") for x in runs)
    # Ollama's chat path drops the oldest messages to fit, so a short loaded context hides in the token counts
    loaded_ctx = resident.get("context_length")
    r["warnings"] = ([f"warm-up failed: {warmup['error']}"] if warmup["error"] else []) + (
        [f"the server loaded {loaded_ctx} tokens of context, under the {ctx} asked: history was dropped"]
        if loaded_ctx and loaded_ctx < ctx else [])
    if paddock is not None:
        r["backend"] = "paddock"
        r["backend_version"] = paddock["version"]
        r["settings"]["max_batch_loaded"] = paddock["max_batch"]
        r["warnings"].append("Paddock weight digest and quantization unavailable: not a matched-model comparison")
        try:
            after = paddock_metadata(root, model, key)
        except (OSError, ValueError, TypeError):
            r["warnings"].append("Paddock runtime metadata could not be verified after measurement")
        else:
            if after != paddock:
                r["warnings"].append("Paddock runtime metadata changed during measurement")
    r["capacity"] = {"agents": agents if not r["warnings"] else None, "levels": levels, "queue_wait_source": "estimated",
                     "prompt_tokens": prompt_tokens}
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
        "warnings": [], "started_at": started, "finished_at": time.time(), "_runs": runs or [],
    }


def write(r, out):
    os.makedirs(out, exist_ok=True)
    name = "-".join([r["kind"], r["evidence"], r["route"], r["host"], r["model"].replace(":", "_").replace("/", "_"), str(r["ctx"])])
    if r.get("backend") == "paddock":
        name += "-paddock"
    runs = r.pop("_runs", [])
    with open(os.path.join(out, name + ".json"), "w", encoding="utf-8") as f:
        json.dump(r, f, indent=1, sort_keys=True)
        f.write("\n")
    # private: per-run timings, never committed with the aggregate or read by the rules; an import has none
    if runs:
        with open(os.path.join(out, name + ".runs.jsonl"), "w", encoding="utf-8") as f:
            f.writelines(json.dumps(run, sort_keys=True) + "\n" for run in runs)
    return os.path.join(out, name + ".json")


TABLE = ["host", "model", "quant", "ctx", "evidence", "route", "vram_load_gib", "vram_steady_gib", "headroom_gib", "gpu_offload",
         "decode_tps_p50", "ttft_warm_p50_s", "ttft_warm_p95_s", "ttft_cold_p50_s", "cold_load_s", "agent_capacity",
         "g1", "fit", "failed_checks", "warnings"]


def table_row(r):
    m = {k: (v or {}).get("value") for k, v in r.get("metrics", {}).items()}
    gib = lambda b: None if b is None else round(b / GIB, 2)
    rnd = lambda x, n=2: None if x is None else round(x, n)
    return {
        "host": r["host"], "model": r["model"], "quant": r["quant"], "ctx": r["ctx"], "evidence": r["evidence"], "route": r["route"],
        "vram_load_gib": gib(m.get("vram_load_bytes")), "vram_steady_gib": gib(m.get("vram_steady_bytes")),
        "headroom_gib": gib(m.get("vram_headroom_bytes")), "gpu_offload": rnd(m.get("gpu_offload_ratio")),
        "decode_tps_p50": rnd(m.get("decode_tps_p50"), 1), "ttft_warm_p50_s": rnd(m.get("ttft_warm_p50")),
        "ttft_warm_p95_s": rnd(m.get("ttft_warm_p95")), "ttft_cold_p50_s": rnd(m.get("ttft_cold_p50")),
        "cold_load_s": rnd(m.get("cold_load_p50")), "agent_capacity": (r.get("capacity") or {}).get("agents"),
        "g1": r.get("g1"), "fit": r["fit"], "failed_checks": " ".join(k for k, c in r.get("checks", {}).items() if c["pass"] is False),
        "warnings": " | ".join(r.get("warnings", [])),
    }


# ---- historical MSI ---------------------------------------------------------------------------------------------

def import_msi(src, out, commit):
    """homelab-gitops colibri-msi results at `commit`, Ollama on msi's CPU at a 16K context (its msi-host.json /api/ps):
    one historical row per model. Only the decode rate is comparable: its TTFTs mix an 86-token and a 1.9K-token prompt,
    so none is carried over. homelab-gitops is private, so this reads a checkout and only the aggregate is committed."""
    written = []
    for fname, model in (("ollama-qwen25c7.jsonl", "qwen2.5-coder:7b"), ("ollama-llama31.jsonl", "llama3.1:8b")):
        data = Path(src, fname).read_bytes()
        rows = [json.loads(l) for l in data.decode("utf-8").splitlines() if l.strip()]
        r = result("fit", "msi-ms7758", model, 16384, {"quant": "Q4_K_M"}, rows[0]["t"] if rows else 0, evidence="historical",
                   fixture={"name": f"homelab-gitops@{commit} docs/decisions/assets/colibri-msi/results/{fname}",
                            "sha256": hashlib.sha256(data).hexdigest()},
                   samples={"warm": len(rows), "cold": 0})
        r["metrics"] = {
            # the archived client's tokens over its own clock, not Ollama's eval timings
            "decode_tps_p50": metric(quantile([x.get("decode_tok_s") for x in rows], 0.5), "tokens/s", "client_measured", len(rows)),
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
        # Ollama's prompt cache: a prompt identical to the last one prefills almost nothing
        self.last_prompt = None
        self.cache_hits = 0
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
            self.reply({"models": [{"name": m, "digest": "sha256:" + "0" * 64,
                                    "details": {"quantization_level": "Q4_K_M", "parameter_size": "7B"}}
                                   for m in (self.MODEL, "mock:tools")]})
        elif self.path == "/api/ps":
            self.reply({"models": [] if s.loaded is None else [{"name": s.loaded, "size": 6 * GIB, "size_vram": 6 * GIB,
                                                                 "context_length": 8192, "digest": "sha256:" + "0" * 64,
                                                                 "details": {"quantization_level": "Q4_K_M"}}]})
        elif self.path == "/api/version":
            self.reply({"version": "0.0.0-mock"})
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
            prompt = json.dumps(body.get("prompt") or body.get("messages"))
            cached = prompt == s.last_prompt
            s.last_prompt = prompt
            s.cache_hits += cached
            prompt_tokens = 8 if cached else 2048
            time.sleep(0 if cached else self.PREFILL_S)
            if self.path == "/api/generate":
                # the G1 bench's request: stream false, Ollama's own timings in the one reply
                time.sleep(self.TOKENS * self.TOKEN_S)
                self.reply({"done": True, "load_duration": int(load * 1e9), "prompt_eval_count": prompt_tokens,
                            "prompt_eval_duration": int((0.001 if cached else self.PREFILL_S) * 1e9),
                            "eval_count": self.TOKENS, "eval_duration": int(self.TOKENS * self.TOKEN_S * 1e9),
                            "total_duration": int((load + self.PREFILL_S + self.TOKENS * self.TOKEN_S) * 1e9)})
            elif self.path == "/v1/chat/completions":
                def sse():
                    if body.get("model") == "mock:tools":
                        # Ollama's /v1 sends a tool call whole, in one delta at the end
                        time.sleep(self.TOKENS * self.TOKEN_S)
                        call = {"index": 0, "id": "c0", "type": "function",
                                "function": {"name": "run", "arguments": "{\"command\": \"true\"}"}}
                        yield b"data: " + json.dumps({"choices": [{"delta": {"tool_calls": [call]}}]}).encode() + b"\n\n"
                        yield b"data: " + json.dumps({"choices": [], "usage": {"completion_tokens": 20,
                                                                               "prompt_tokens": prompt_tokens}}).encode() + b"\n\n"
                        yield b"data: [DONE]\n\n"
                        return
                    for i in range(self.TOKENS):
                        time.sleep(self.TOKEN_S)
                        yield b"data: " + json.dumps({"choices": [{"delta": {"content": "x"}}]}).encode() + b"\n\n"
                    yield b"data: " + json.dumps({"choices": [], "usage": {"completion_tokens": self.TOKENS,
                                                                           "prompt_tokens": prompt_tokens}}).encode() + b"\n\n"
                    yield b"data: [DONE]\n\n"
                self.stream(sse())
            else:
                self.send_error(404)


def mock(out, limits_path=None):
    srv = FakeOllama()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    limits = thresholds(limits_path or os.path.join(FIXTURES, "mock-thresholds.json"))
    try:
        paths = [write(capacity(srv.base + "/v1", "mock-host", FakeHandler.MODEL, 4096, "direct", max_n=6,
                                per_level=20, limits=limits), out)]
    finally:
        srv.shutdown()
    return paths


# ---- CLI --------------------------------------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog="llm-bench", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("import-g1")
    g.add_argument("--src", required=True, help="a G1 results directory: g1-*.jsonl and vram-*.csv")
    g.add_argument("--out", required=True)
    c = sub.add_parser("capacity")
    c.add_argument("--base", required=True, help="OpenAI-compatible base ending in /v1")
    c.add_argument("--backend", choices=("ollama", "paddock"), default="ollama",
                   help="direct backend metadata API; Paddock requires --route direct")
    c.add_argument("--host", required=True)
    c.add_argument("--model", required=True)
    # /v1 takes no num_ctx: the server's loaded context applies (asus: OLLAMA_CONTEXT_LENGTH 32768), so 8192 only
    # measures where that context is loaded, and otherwise warns and gives no number
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
    if a.cmd == "import-g1":
        print("\n".join(import_g1(a.src, a.out)))
    elif a.cmd == "capacity":
        key = Path(a.key_file).read_text(encoding="utf-8").strip() if a.key_file else None
        print(write(capacity(a.base, a.host, a.model, a.ctx, a.route, key, a.max_agents, a.per_level,
                             backend=a.backend), a.out))
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
