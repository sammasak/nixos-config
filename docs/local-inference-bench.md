# Local-inference benchmark: the runs behind the scorecard

The asus model-fit table and the agent capacity per model (#491, #493) come from two runs and one import. G1 has one
contract: the fixture, sampling and rule of `scripts/ollama-g1-bench.sh` and `scripts/ollama-g1-table.py` (#492).
`llm-bench import-g1` carries that output into the committed scorecard (`pkgs/llm-bench/scorecard/`), which becomes
black-pi's `llm_bench:*` recording rules and the "Local inference" row of the LLM gateway dashboard.

All commands run from acer: asus's and msi's Ollama admit acer only. Use a nixos-config checkout on acer, since the
bench reads its fixture from git at a pinned commit.

## 1. G1: one row per model and context

On asus, log VRAM at 1 Hz for the whole run (stop it with Ctrl-C afterwards):

```
nvidia-smi --query-gpu=timestamp,memory.used,memory.total --format=csv -lms 1000 > vram-asus.csv
```

From acer, for each tag asus pins in `homelab.ollama.modelDigests` (`hosts/asus-b460m/configuration.nix`) and both
contexts: 5 cold runs and 20 warm runs, so that p95 has its 20 samples.

```
mkdir -p ~/g1 && cd ~/nixos-config
for m in qwen2.5-coder:7b-instruct-q4_K_M gemma4:e4b-it-qat gemma4:e2b-it-qat; do
  for c in 4096 8192; do
    scripts/ollama-g1-bench.sh 192.168.10.113 "$m" "$c" 5 20 ~/g1/g1-asus-"${m//:/_}"-"$c".jsonl
  done
done
```

msi's row for the same model and context sets the decode bar at 5× msi's. Run it in msi's Mon-Fri 09:00-21:00
window, and only for tags msi loads, here `qwen2.5-coder:7b-instruct-q4_K_M`:

```
for c in 4096 8192; do
  scripts/ollama-g1-bench.sh 192.168.10.235 qwen2.5-coder:7b-instruct-q4_K_M "$c" 5 20 ~/g1/g1-msi-qwen-"$c".jsonl
done
```

Copy `vram-asus.csv` into `~/g1`. Then print the G1 table and turn the one-client rows into scorecard results:

```
python3 scripts/ollama-g1-table.py ~/g1
nix run .#llm-bench -- import-g1 --src ~/g1 --out pkgs/llm-bench/scorecard
nix run .#llm-bench -- table pkgs/llm-bench/scorecard/*.json
```

A row with a "prompt cache" warning is never a fit. The bench puts a nonce line first in every request for this
reason. Without it, Ollama serves the warm prefill from cache.

## 2. Agent capacity per model

The agent count comes from `llm-bench capacity`: Pi-shaped streamed `/v1` turns ramped to 8 concurrent agents. It
is judged against `pkgs/llm-bench/thresholds.json` `capacity` (proposed). The multi-client rows of the G1 bench
(its `CLIENTS` argument) show raw queueing only.

```
for m in qwen2.5-coder:7b-instruct-q4_K_M gemma4:e4b-it-qat gemma4:e2b-it-qat; do
  nix run .#llm-bench -- capacity --base http://192.168.10.113:11434/v1 --host asus-b460m --model "$m" \
    --ctx 4096 --route direct --out ~/capacity
done
```

- **The server's context applies.** `/v1` takes no `num_ctx`, so the loaded context is the server's
  `OLLAMA_CONTEXT_LENGTH`. asus sets 32768, so `--ctx 4096` and `--ctx 8192` both measure, with a 32K KV cache
  (`context_length_loaded` in the result). Capacity results from before that change were taken at a loaded 4096.
- **Through the gateway**, once asus is in its catalog (llm-gateway#101): `--base http://127.0.0.1:8081/v1 --route
  gateway --key-file /run/secrets/llm_gateway_pi_key`, the Pi project key on acer.

## 3. Commit

Copy only the aggregates: `cp ~/capacity/*[0-9].json pkgs/llm-bench/scorecard/`. Never copy a `*.runs.jsonl`
(per-run timings): `scripts/test-llm-bench.py` fails on one. The import already writes into `scorecard/`.

Open a PR. The gate renders the rules, so an unlisted model or label fails it. List a new tag in
`pkgs/llm-bench/models.nix`; the build fails when a host loads a tag that is not listed.

## 4. GPU telemetry live: flip asus's `gpu` fact

Only after #492's deploy and reboot. On asus, check that the driver accepts every field the exporter asks for:

```
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw,clocks_throttle_reasons.active,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_power_cap --format=csv
```

- **If it prints a data row:** set `asus-b460m.gpu = "nvidia"` in `modules/core/fleet.nix` (a one-line PR). After
  the deploy, on black-pi:
  - `up{job="nvidia-gpu"}` is 1;
  - `nvidia_smi_memory_total_bytes{node="asus-b460m"}` is about 8 GiB;
  - `avg_over_time(up{job="nvidia-gpu"}[2h])` is 1 while asus is on;
  - `GpuTelemetryDown` is inactive.
- **If it refuses a field:** drop that field from `homelab.gpuTelemetry.fields` (`modules/homelab/monitoring/gpu-exporter.nix`)
  first. The exporter refuses to start on a field the driver rejects.
