"""The G1 table (#491, #492) from one results directory: one row per host, model, context and client count.

Reads the bench's g1-*.jsonl and the nvidia-smi logs (vram-*.csv, written on the GPU host while the bench ran there).
VRAM at load is the peak over the cold runs, steady state the median over the warm runs, headroom the card's total
minus the warm peak. G1 for a one-client GPU row: headroom >= 768 MiB at 4096, every layer on the GPU (gpu_share 1),
and decode tok/s p50 >= 5x the msi row for the same model and context (>= 24 without one). Rows with more clients
show raw queueing only: the agent-capacity number is llm-bench capacity's (Pi-shaped /v1 turns, pkgs/llm-bench), and
`llm-bench import-g1 DIR` carries this table's one-client rows into the scorecard.
usage: python3 ollama-g1-table.py DIR
"""
import csv
import glob
import json
import math
import os
import statistics
import sys
from datetime import datetime

MSI = "192.168.10.235"


def q(xs, p):
    xs = sorted(xs)
    return xs[math.ceil(len(xs) * p) - 1] if xs else None


def vram_samples(d):
    out = []
    for path in glob.glob(os.path.join(d, "vram-*.csv")):
        with open(path) as f:
            for row in csv.DictReader(f, skipinitialspace=True):
                ts = datetime.strptime(row["timestamp"], "%Y/%m/%d %H:%M:%S.%f").timestamp()
                out.append((ts, int(row["memory.used [MiB]"].split()[0]), int(row["memory.total [MiB]"].split()[0])))
    return out


def during(samples, runs):
    return [s for s in samples if any(r["t_start"] <= s[0] <= r["t_end"] for r in runs)]


def fmt(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}" if isinstance(x, float) else str(x)


d = sys.argv[1]
runs = [json.loads(l) for p in sorted(glob.glob(os.path.join(d, "g1-*.jsonl"))) for l in open(p) if l.strip()]
smi = vram_samples(d)
groups = {}
for r in runs:
    groups.setdefault((r["host"], r["model"], r["ctx"], r.get("clients", 1)), []).append(r)
msi_decode = {(m, c): q([r["decode_tok_s"] for r in rs if r["kind"] == "warm"], 0.5)
              for (h, m, c, n), rs in groups.items() if h == MSI and n == 1}

print("| host | model | ctx | clients | n cold/warm | VRAM load MiB | VRAM steady MiB | headroom MiB | gpu_share min "
      "| decode tok/s p50 | TTFT p50/p95 s | TTFT queued p95 s | cold load p50 s | G1 |")
print("|" + "---|" * 14)
for (host, model, ctx, clients), rs in sorted(groups.items()):
    cold = [r for r in rs if r["kind"] == "cold"]
    warm = [r for r in rs if r["kind"] == "warm"]
    vc, vw = during(smi, cold), during(smi, warm)
    load = max((s[1] for s in vc), default=None)
    steady = statistics.median(s[1] for s in vw) if vw else None
    headroom = vw[0][2] - max(s[1] for s in vw) if vw else None
    share = min((r["gpu_share"] for r in rs if r["gpu_share"] is not None), default=None)
    decode = q([r["decode_tok_s"] for r in warm], 0.5)
    verdict = "-"
    if host != MSI and clients == 1:
        need = 5 * msi_decode[(model, ctx)] if (model, ctx) in msi_decode else 24
        fails = []
        if ctx == 4096 and (headroom is None or headroom < 768):
            fails.append(f"headroom {fmt(headroom)} < 768")
        if share is None or share < 1:
            fails.append(f"gpu_share {fmt(share, 2)}")
        if decode is None or decode < need:
            fails.append(f"decode {fmt(decode)} < {need:.1f}")
        verdict = "no-go: " + ", ".join(fails) if fails else "pass"
    ttft = [r["ttft_s"] for r in warm]
    print(f"| {host} | {model} | {ctx} | {clients} | {len(cold)}/{len(warm)} | {fmt(load)} | {fmt(steady)} "
          f"| {fmt(headroom)} | {fmt(share, 2)} | {fmt(decode)} | {fmt(q(ttft, 0.5), 2)}/{fmt(q(ttft, 0.95), 2)} (n {len(ttft)}) "
          f"| {fmt(q([r['ttft_queued_s'] for r in warm if 'ttft_queued_s' in r], 0.95), 2)} "
          f"| {fmt(q([r['load_s'] for r in cold], 0.5), 2)} | {verdict} |")
