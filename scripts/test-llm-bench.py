"""pkgs/llm-bench (nixos-config#493): the harness end to end against its fake Ollama, its statistics and verdicts on
fixed inputs, the MSI import, and what may leave a run: no prompt, completion or run ID in an aggregate, and every
committed scorecard file is an aggregate."""
import glob
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "pkgs", "llm-bench"))
import llm_bench as lb  # noqa: E402

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


# quantile floors: p50 from 5 samples, p95 from 20, never a number below them
check(lb.quantile([1.0] * 4, 0.5) is None and lb.quantile([1.0] * 5, 0.5) == 1.0, "p50 needs 5 samples")
check(lb.quantile(list(range(19)), 0.95) is None and lb.quantile(list(range(1, 21)), 0.95) == 19, "p95 needs 20 samples (nearest rank)")
check(lb.quantile([None] * 30, 0.5) is None, "missing values are not samples")
check(lb.metric(None, "s", "client_measured", 4)["source"] == "insufficient_samples"
      and lb.metric(None, "s", "prometheus")["source"] == "unavailable", "a null value says why it is null")

limits = lb.thresholds()
check(limits["status"].startswith("proposed"), "the thresholds are marked proposed until the owner confirms them")


def fit_result(**values):
    m = {k: lb.metric(None, "", "unavailable") for k in
         ("vram_headroom_bytes", "gpu_offload_ratio", "decode_tps_p50", "ttft_warm_p95", "cold_load_p50")}
    for k, v in values.items():
        m[k] = lb.metric(v, "", "provider_reported")
    return lb.judge_fit({"model": "qwen2.5-coder:7b", "ctx": 4096, "metrics": m}, limits)


good = dict(vram_headroom_bytes=1.0 * lb.GIB, gpu_offload_ratio=1.0, decode_tps_p50=30.0, ttft_warm_p95=1.0, cold_load_p50=10.0)
check(fit_result(**good)["fit"] == "yes", "every fit check inside its threshold is a fit")
bad = fit_result(**{**good, "decode_tps_p50": 20.0})
check(bad["fit"] == "no" and bad["checks"]["decode"]["pass"] is False, "Qwen 7B under 24 tok/s is no fit, naming the decode check")
partial = fit_result(**{k: v for k, v in good.items() if k != "vram_headroom_bytes"})
check(partial["fit"] == "not_evaluated" and partial["checks"]["headroom"]["pass"] is None,
      "without a VRAM reading the fit is not evaluated, never passed")
check(fit_result(**{**good, "gpu_offload_ratio": 0.8})["fit"] == "no", "a model partly on the CPU is no fit")


def level(n, ttft, tps, wait, errors=0):
    return {"agents": n, "errors": errors, "ttft_p95": ttft, "decode_tps_per_agent_p50": tps, "queue_wait_p95": wait}


check(lb.agent_capacity([level(1, 1, 30, 0), level(2, 2, 25, 1), level(3, 6, 20, 4)], limits) == 2,
      "capacity is the last level inside every threshold")
check(lb.agent_capacity([level(1, 1, 30, 0), level(2, 2, 25, 1, errors=1)], limits) == 1, "a level with errors ends the ramp")
check(lb.agent_capacity([level(1, None, 30, 0)], limits) is None, "an unevaluable first level gives no capacity, not 0")
check(lb.agent_capacity([level(1, 9, 30, 0)], limits) == 0, "a first level outside the thresholds gives 0 agents")

a, b = lb.long_prompt(4096), lb.long_prompt(4096)
check(a == b and lb.long_prompt(8192)[1] != a[1] and len(lb.long_prompt(8192)[0]) > len(a[0]),
      "the fit fixture is byte-identical per context size, and 8K is longer than 4K")
check(lb.agent_turn(4096)[2] == lb.agent_turn(4096)[2], "the agent fixture is byte-identical")

with tempfile.TemporaryDirectory() as tmp:
    run = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "pkgs", "llm-bench", "llm_bench.py"), "mock", "--out", tmp],
                         capture_output=True, text=True, timeout=300)
    check(run.returncode == 0, f"llm-bench mock runs ({run.stderr[-400:]})")
    results = {os.path.basename(p): json.load(open(p)) for p in glob.glob(os.path.join(tmp, "*.json"))}
    fits = [r for r in results.values() if r["kind"] == "fit"]
    caps = [r for r in results.values() if r["kind"] == "capacity"]
    check(sorted(r["ctx"] for r in fits) == [4096, 8192] and len(caps) == 1, f"mock: a fit per context size and one capacity run {sorted(results)}")
    for r in fits:
        check(r["samples"] == {"warm": 20, "cold": 5} and r["fit"] == "yes" and r["digest"] and r["fixture"]["sha256"],
              f"mock fit {r['ctx']}: 20 warm and 5 cold, identified, judged ({r['fit']}, {r['samples']})")
        check(r["metrics"]["vram_headroom_bytes"]["source"] == "prometheus" and r["metrics"]["decode_tps_p50"]["source"] == "provider_reported",
              f"mock fit {r['ctx']}: VRAM from Prometheus, decode from Ollama's own timings")
    if caps:
        c = caps[0]["capacity"]
        mock_limits = lb.thresholds(os.path.join(ROOT, "pkgs", "llm-bench", "fixtures", "mock-thresholds.json"))
        inside = [lb.within(lv, mock_limits) for lv in c["levels"]]
        n = c["agents"]
        check(isinstance(n, int) and n >= 1 and all(inside[:n]) and (len(inside) == n or inside[n] is False),
              f"mock capacity {n}: every level up to it inside the thresholds, the next one outside ({inside})")
        check(c["queue_wait_source"] == "estimated", "queue wait is labelled estimated")
    corpus = lb.load_json(os.path.join(lb.FIXTURES, "long-context.json"))["corpus"]
    task = lb.load_json(os.path.join(lb.FIXTURES, "agent-turn.json"))["task"]
    for name, r in results.items():
        text = json.dumps(r)
        check("_runs" not in r and not any(s[:40] in text for s in corpus + [task]), f"{name}: an aggregate, no prompt text")
    runs = [json.loads(l) for p in glob.glob(os.path.join(tmp, "*.runs.jsonl")) for l in open(p) if l.strip()]
    check(runs and not any({"text", "prompt", "response", "content", "id"} & set(r) for r in runs),
          "the private runs file holds timings, no prompt, completion or ID")

with tempfile.TemporaryDirectory() as tmp:
    src = os.path.join(tmp, "src")
    os.mkdir(src)
    for f, tps in (("ollama-qwen25c7.jsonl", 4.8), ("ollama-llama31.jsonl", 4.5)):
        with open(os.path.join(src, f), "w") as fh:
            for i in range(6):
                fh.write(json.dumps({"text": "secret completion", "ttft_s": 7.0 + i, "decode_tok_s": tps, "t": 1.0}) + "\n")
    out = lb.import_msi(src, os.path.join(tmp, "out"), "0" * 40)
    rows = [json.load(open(p)) for p in out]
    check(len(rows) == 2 and all(r["evidence"] == "historical" and r["host"] == "msi-ms7758" for r in rows),
          "import-msi: one historical msi row per model")
    check(sorted(r["metrics"]["decode_tps_p50"]["value"] for r in rows) == [4.5, 4.8]
          and all(r["metrics"]["gpu_offload_ratio"]["value"] is None for r in rows),
          "import-msi: the measured decode rate, and no GPU value for a CPU host")
    check(not any("secret completion" in json.dumps(r) for r in rows), "import-msi: no completion text is carried over")

committed = glob.glob(os.path.join(ROOT, "pkgs", "llm-bench", "scorecard", "*"))
check(committed and all(p.endswith(".json") for p in committed), f"the scorecard holds aggregates only, no runs files {committed}")
for p in committed:
    r = json.load(open(p))
    check(r.get("schema") == lb.SCHEMA and "_runs" not in r and r["evidence"] in ("measured", "historical"),
          f"{os.path.basename(p)}: an llm-bench/1 aggregate")

print(f"{'FAIL' if failed else 'ok'}: {failed} failed")
sys.exit(1 if failed else 0)
