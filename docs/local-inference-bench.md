# Local-inference benchmark: the runs behind the scorecard

The asus model-fit table and the agent capacity per model (#491, #493) come from two runs and one import. G1 has one
contract: the fixture, sampling and rule of `scripts/ollama-g1-bench.sh` and `scripts/ollama-g1-table.py` (#492).
`llm-bench import-g1` carries that output into the committed scorecard (`pkgs/llm-bench/scorecard/`), which becomes
black-pi's `llm_bench:*` recording rules and the "Local inference" row of the LLM gateway dashboard. Section 5 holds
the measured asus baseline, its limits and the records behind it.

All commands run from acer: asus's and msi's Ollama admit acer only. Use a nixos-config checkout on acer, since the
bench reads its fixture from git at a pinned commit.

For fan, power and useful Pi-task capacity constraints, follow the
[ASUS quiet-capacity protocol](asus-quiet-agent-capacity.md) before changing concurrency.

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

msi's row for the same model and context sets the decode bar at 5× msi's. Run it in msi's Mon-Fri ~08:30-21:00
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
- **No pi session beside a G1 or capacity run.** A `/v1` client loads the model at the server's 32K and the bench at
  its own `num_ctx`, so every switch between them reloads the model and lands a load in the warm rows. Hold
  `/run/work-locks/heavy-work.lock` for the run, as nixos:qa does (scripts/heavy-lock.sh).
- **Through the gateway**, once asus is in its catalog (llm-gateway#101): `--base http://127.0.0.1:8081/v1 --route
  gateway --key-file /run/secrets/llm_gateway_pi_key`, the Pi project key on acer.

### Paddock metadata and comparison readiness

After the separately approved native Paddock CUDA/API canary (#508), the existing capacity harness can collect
streamed timings directly from its alternate endpoint:

```
nix run .#llm-bench -- capacity --backend paddock --route direct \
  --base http://192.168.10.113:11660/v1 --host asus-b460m --model YOUR_SERVED_MODEL_ID \
  --ctx 4096 --max-agents 1 --per-level 20 --out ~/capacity
```

Use the actual primary model ID from `/api/server`, not a guessed filename or alias. The harness checks the runner
identity, `/v1/models` entry and their agreement on loaded context before sending inference traffic. It records actual
context and batch limits, sends an optional `--key-file` bearer token to metadata and inference endpoints, and checks
runtime metadata again afterward. Missing, contradictory or changed metadata cannot validate a capacity. Paddock
artifacts have a `-paddock` suffix so they cannot overwrite an Ollama result for the same host/model/context.

The current runner metadata API does not expose a verified GGUF digest or quantization. Those fields remain null,
the aggregate explicitly warns that it is not a matched-model comparison, and its validated agent count remains
null. Timing rows are retained for diagnosis. This support does not prove CUDA residency or tool correctness.

Before claiming an engine improvement (#493), verify identical weight bytes/hash, tokenizer, rendered prompt,
quantization, actual context, sampling and cache policy on both engines; record any KV dtype difference. A common
model name or an Ollama manifest digest does not establish identical weight bytes. Use one resident engine at a
time, retain the 130 W cap, and keep cold/warm and direct/gateway results separate. Actual Pi read/edit/bash task
success remains #494; these synthetic streamed turns do not measure useful coding capacity. Gateway integration
remains llm-gateway#102; `--backend paddock --route gateway` is refused rather than bypassing backend checks.

## 3. Commit

Copy only the aggregates: `cp ~/capacity/*[0-9].json pkgs/llm-bench/scorecard/`. Never copy a `*.runs.jsonl`
(per-run timings): `scripts/test-llm-bench.py` fails on one. The import already writes into `scorecard/`.

Open a PR. The gate renders the rules, so an unlisted model or label fails it. List a new tag in
`pkgs/llm-bench/models.nix`; the build fails when a host loads a tag that is not listed.

## 4. GPU telemetry live: flip asus's `gpu` fact

Only after #492's deploy and reboot. On asus, check that the driver accepts every field the exporter asks for:

```
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw,power.limit,fan.speed,clocks_throttle_reasons.active,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_power_cap --format=csv
```

- **If it prints a data row** (it did on 18 Nov, driver 595.104.02, all 14 fields): set `asus-b460m.gpu = "nvidia"` in
  `modules/core/fleet.nix` (done, #493's telemetry slice). After
  the deploy, on black-pi:
  - `up{job="nvidia-gpu"}` is 1;
  - `nvidia_smi_memory_total_bytes{node="asus-b460m"}` is about 8 GiB;
  - `avg_over_time(up{job="nvidia-gpu"}[2h])` is 1 while asus is on;
  - `GpuTelemetryDown` is inactive.
- **If it refuses a field:** drop that field from `homelab.gpuTelemetry.fields` (`modules/homelab/monitoring/gpu-exporter.nix`)
  first. The exporter refuses to start on a field the driver rejects.

## 5. The asus baseline (#493)

The figures below come only from six measurement reports, kept verbatim in `docs/records/` as this section's artifacts.
Each figure names its report. The raw files the reports cite (per-request JSONL, GPU logs, journals) stayed in the run
host's `~/.local/state/fleet-lead/` and are not in the repo.

| Short name | Record | What it measured |
|---|---|---|
| g1 | `docs/records/llm-baseline-g1-result.md` | G1 run, all three pinned tags, 4K and 8K, plus agent capacity; 17 Nov, 270 W |
| stress | `docs/records/llm-baseline-g1-stress-run.md` | qwen 30-minute one-request stress, runs 1 to 3; 18 Nov, 130 W |
| ctx | `docs/records/llm-baseline-ctx-result.md` | context ceiling 4K to 128K and long Pi-shaped sessions; 17 Nov, 130 W |
| swap | `docs/records/llm-baseline-swap-32k.md` | qwen and gemma4:e4b swapping at 32K; 17 Nov, 130 W |
| pi | `docs/records/llm-baseline-pi-32k-result.md` | real `pi` sessions at 32K, judged by tests; 17 Nov, 130 W |
| closeout | `docs/records/llm-baseline-g1-closeout.md` | #492 and #493 boxes against the evidence; 18 Nov |

None of them holds a token or secret. The `"apiKey": "ollama"` in the ctx and pi records is the placeholder Ollama
ignores. Their `~/.cache/...` and `~/.local/state/...` paths are the run host's working files, kept so the reports stay
verbatim.

### Baseline table

asus-b460m: RTX 3070 (8192 MiB, of which 359 reserved and 7833 usable), driver 595.104.02, Ollama 0.40.3 CUDA,
`OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1` (stress, swap, ctx). Every row ran 100 % on the GPU: every
layer offloaded and `size_vram == size` (g1, stress).

A tag is pinned by its registry manifest digest in `homelab.ollama.modelDigests` (`hosts/asus-b460m/configuration.nix`):
qwen2.5-coder:7b-instruct-q4_K_M `dae161e2…` (the digest the stress run captured per request), gemma4:e4b-it-qat
`ee665637…`, gemma4:e2b-it-qat `07ea59a4…`. The g1 run found all three at their pinned digests in `/api/tags`.

| Model (quant) | Cap | ctx | n cold / warm | Decode tok/s p50 | TTFT warm p50 / p95 s | VRAM steady MiB | Headroom MiB of 8192 | Cold load p50 s | Source |
|---|---|---|---|---|---|---|---|---|---|
| qwen2.5-coder:7b-instruct-q4_K_M (Q4_K_M) | 130 W | 4096 | 1 / 400 | 70.0 | 0.952 / 0.971 | 4639 | 3553 | | stress, run 3 |
| qwen2.5-coder:7b-instruct-q4_K_M | 130 W | 8192 | 1 / 10 | 65.9 | 1.75 / 1.75 | 4909 | 3283 | | stress, run 3 |
| qwen2.5-coder:7b-instruct-q4_K_M | 270 W | 4096 | 5 / 20 | 75.4 | 0.76 / 0.80 | 4639 | 3553 | 1.98 | g1 |
| qwen2.5-coder:7b-instruct-q4_K_M | 270 W | 8192 | 5 / 20 | 71.7 | 1.47 / 1.50 | 4909 | 3283 | 1.99 | g1 |
| gemma4:e4b-it-qat (Q4_0) | 270 W | 4096 | 5 / 20 | 87.7 | 0.68 / 0.70 | 4247 | 3945 | 2.77 | g1 |
| gemma4:e4b-it-qat | 270 W | 8192 | 5 / 20 | 85.0 | 1.28 / 1.33 | 4285 | 3907 | 2.80 | g1 |
| gemma4:e2b-it-qat (Q4_0) | 270 W | 4096 | 5 / 20 | 148.3 | 0.41 / 0.41 | 2861 | 5331 | 2.50 | g1 |
| gemma4:e2b-it-qat | 270 W | 8192 | 5 / 20 | 143.3 | 0.74 / 0.75 | 3013 | 5179 | 2.50 | g1 |

Quants are as the closeout states them. TTFT here is Ollama's own (load plus prompt eval).

- **Rejected, not measured:** `llama3.1:8b`, `gemma3:4b-it-qat` and `qwen3.5:4b`. None is in `homelab.ollama.modelDigests`,
  so asus does not have them as deployed. Pulling one is a config change, and pinning them or accepting the rejection is
  the owner's call (closeout).
- **Agent capacity:** qwen sustains 2 closed-loop agents under the proposed `capacity` thresholds. gemma4 was not
  evaluable: both models spent the 128-token budget on reasoning (g1).
- **As a `pi` agent:** 0 of 9 real sessions with gemma4 produced a correct, test-verified result. qwen2.5-coder emits no
  structured tool calls through `/v1` (pi, ctx).
- **Long contexts at 130 W**, 4K to 128K per model: the ctx record's ceiling table.

### Re-run

Per model and context: `scripts/ollama-g1-bench.sh HOST MODEL CTX COLD WARM OUT.jsonl [CLIENTS]`, then
`python3 scripts/ollama-g1-table.py DIR`, as in section 1, holding `/run/work-locks/heavy-work.lock`. The stress
row is one invocation of 1 cold and 400 warm requests (stress):

```
scripts/ollama-g1-bench.sh 192.168.10.113 qwen2.5-coder:7b-instruct-q4_K_M 4096 1 400 ~/g1-stress/g1-stress.jsonl
```

Both scripts exist on main. The drivers the records name under `~/.cache/g1-run/bin/` (`g1-main.sh`, `g1-stress.sh`,
`ctx_ceiling.py`, `long_session.py`, `swap32k_chat.py`, `pi_session.sh`, `pi_calls.py`) were never committed, so the ctx,
swap and pi measurements have no command on main; each record quotes the requests it sent.

### Measurement limits

- **Sample counts.** Per row in the table. Capacity: 20 to 21 requests per level (g1). Context ceiling: 1 cold and 1
  warm request per row, VRAM peaks from 0.5 s samples (ctx). Swap: 4 loads, each direction twice, 209 samples at 0.2 s
  (swap). `pi`: 9 sessions, one or two per task, so the failure pattern is clear but no rate is (pi). The other GPU
  logs are 1 Hz.
- **Nearest-rank quantiles.** `scripts/ollama-g1-table.py` takes the sorted value at rank ceil(n × p), with no
  interpolation. With n 20, p95 is the 19th value, the second slowest request, so two requests decide it. With n 10, p95
  is the maximum, which is why the 8K stress row reads 1.75 / 1.75.
- **Power is the GPU's only.** It is nvidia-smi `power.draw`, the board's draw, not the host at the wall. No energy per
  token is given.
- **270 W against 130 W.** The g1 rows ran before the 130 W cap (`homelab.ollama.gpuPowerLimit`); stress, ctx, swap and
  pi ran at 130 W. qwen at 4K decodes 75.4 tok/s at 270 W and 70.0 at 130 W, with different sample counts. Prefill at
  270 W for long contexts was not measured (ctx).
- **VRAM headroom is measured on an idle desktop.** asus runs no graphical session; a desktop-in-use scenario was not
  measured (stress, closeout). Headroom is against 8192 MiB, the G1 table's definition; against the 7833 usable it is
  359 MiB less (stress). A load-time VRAM reading can include the previous model during its swap-out: g1's e2b 4K load
  read 4285 MiB (g1). Each load also maps a fixed host-memory buffer (`CPU_Mapped`, 292.36 MiB for qwen, 2730.00 MiB for
  e4b), the same at every context; it is not a spill (swap).
- **The prompt cache.** A repeated prompt is served from the runner's cache: stress run 1 reused 20 prompts, so its TTFT
  of 0.016 s is invalid, and the bench puts a nonce first in every request for this reason. The cache's host-RAM limit
  was 8192 MiB, the whole `MemoryMax=8G`: run 2's runner was OOM-killed after 97 distinct 4K prompts (stress). #551 caps
  it at 1024 MiB (`homelab.ollama.promptCacheMiB`, `modules/homelab/ollama-host.nix`), and run 3 plateaued at about
  968 MiB. The g1, ctx, swap and pi rows ran before that cap.
- **Quantization.** qwen is Q4_K_M and gemma4 is a QAT Q4_0, so rows across models compare different quants as well as
  models.
- **Where the client sat.** g1 and stress ran from asus against its own LAN address, so client wall times have no LAN
  hop; Ollama's timings are unaffected (g1). No msi row was taken, so the decode bar is the 24 tok/s floor, not 5× msi.
  Gateway latency was not measured: asus is not in the gateway's catalog (closeout, llm-gateway#101).
- **qwen above 32768 truncates silently:** Ollama clamps to 32768 and evaluates part of the prompt, with no error (ctx).

### GPU readings in Prometheus

On black-pi's Prometheus or Grafana Explore. The job is `nvidia-gpu`, scraped every 10 s with `node` and `instance`
labels (`modules/homelab/monitoring/prometheus.nix`); the metric names are the ones
`modules/homelab/monitoring/dashboards/gpu.json` reads. The closeout gives these for a 2-hour known-on window. Its run
could not reach Prometheus from asus, so no value is recorded yet.

```
up{job="nvidia-gpu",node="asus-b460m"}
avg_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])          # the box: >= 0.99
count_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])
max_over_time(nvidia_smi_memory_used_bytes{node="asus-b460m"}[2h])
nvidia_smi_memory_total_bytes{node="asus-b460m"}
max_over_time(nvidia_smi_utilization_gpu_ratio{node="asus-b460m"}[2h])
avg_over_time(nvidia_smi_utilization_gpu_ratio{node="asus-b460m"}[2h])
max_over_time(nvidia_smi_power_draw_watts{node="asus-b460m"}[2h])
max_over_time(nvidia_smi_temperature_gpu{node="asus-b460m"}[2h])
```

### Rollback and recovery

- **Recovery, observed:** after run 2's OOM kill at 15:22:15, systemd restarted Ollama at 15:22:16, and it served the
  8K run with no re-pull (closeout).
- **Rollback, not demonstrated:** generations system-2 to system-14 are present on asus. The command is in
  `docs/nix-audit-pilot.md` "Rollback" (on main it adds `--no-reexec`, which the closeout's quote lacks); running it is
  the owner's call (closeout).
- **Model cache kept:** the models live under `/var/lib/ollama/models`, outside the Nix store, and each loader run after
  a restart received 5.2 to 7.2 KB, so nothing was downloaded again (closeout).
