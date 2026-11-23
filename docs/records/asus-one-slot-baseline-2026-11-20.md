# ASUS one-slot baseline — 20 November 2026

Tracked by #604 and #493. Measured 10:00:58–10:02:16 UTC after the owner's
explicit wake authorization. No configuration activation, model download,
power-policy change or routing change was performed for this measurement.

## Runtime and method

- RTX 3070, 8192 MiB; NVIDIA driver 595.104.02; Ollama 0.40.3.
- Requested and enforced board-power limits: 130 W throughout collection.
- One request slot, one resident model, Flash Attention and q8_0 KV cache.
- Qwen `qwen2.5-coder:7b-instruct-q4_K_M`, digest
  `dae161e27b0e90dd1856c8bb3209201fd6736d8eb66298e75ed87571486f4364`.
- Actual loaded context: 32768. Synthetic fixture setting: 4096; median observed
  prompt tokens: 2530. These are distinct from the configured context window.
- Prebuilt `llm-bench` at
  `/nix/store/8a8drm4847xh7k26a0bddy1f5mr4qimb-llm-bench`, invoked from Acer
  against ASUS's direct `/v1` endpoint, max two offered agents, 20 requests per
  level, 128 maximum output tokens. One unmeasured warmup precedes the levels.
- ASUS's shared heavy-work lock was held through the whole benchmark and GPU
  recording; no other heavy job was started until the lock was released.
- Readiness: no failed systemd units, no resident model initially, exporter and
  Ollama active, neither hardware nor software thermal-slowdown flag active.

## Results

| Offered clients | Requests | Errors | Non-content responses | p95 first token | Median decode tokens/s per request | Estimated p95 queue wait |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 20 | 0 | 0 | 0.906 s | 69.34 | 0 s |
| 2 | 20 | 0 | 0 | 2.902 s | 69.72 | 1.996 s |

The harness reports synthetic capacity 2 with no warnings. Both levels used the
same **one-slot runtime**: offered clients queue; this is not two concurrent
GPU inference slots. Decode speed describes active requests, not aggregate
successful coding tasks per second. This fixture does not execute or validate
Pi-agent tool loops and does not establish coding-task quality.

79 GPU observations, approximately one second apart, covered warmup and the
benchmark. Observed peak temperature was 58°C, fan demand 62%, and GPU memory
5499 MiB. Ollama reported the entire 5540864326-byte loaded model allocation in
VRAM. Both thermal-slowdown flags stayed inactive in the collected samples.
The power-draw observations ranged from 16.20 to 130.44 W while the enforced
limit stayed exactly 130 W; instantaneous board telemetry is not a perfectly
clipped draw ceiling. Fan percentage does not measure audible sound level.

## Evidence and next gate

Private raw receipts live on Lenovo under
`~/.local/state/metrics-cycle-600/asus-baseline-20261120/`: `exit.json`,
`gpu.csv`, `gpu.stderr`, `bench.log`, and `results/`. Benchmark exit status was
0. Raw GPU timestamps are wall-clock samples, without monotonic query brackets;
do not derive precise energy-per-task acceptance from this capture. The prepared
bounded recorder supplies monotonic brackets for the next experiment.

This short run is neither a sustained noise/temperature acceptance test nor a
matched one-slot/two-slot comparison. Next: complete the candidate's source and
build gates, run the same workload at two slots only after activation is
authorized, then test actual tool loops and sustained operation. Keep 130 W,
32K context, model digest and workload fixed. The existing default stays at one
slot until evidence supports changing it.
