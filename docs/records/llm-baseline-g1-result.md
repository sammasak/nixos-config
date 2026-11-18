# G1 result: asus-b460m RTX 3070 8 GB, Ollama 0.40.3 CUDA (nixos-config#492, epic #491), 2026-11-17

Procedure: `docs/local-inference-bench.md` §1–2 at origin/main **563319f** (with #506), in a fresh worktree `~/.cache/wt/g1-main`.
The run held `/run/work-locks/heavy-work.lock` for the whole measurement, 10:48:23–11:03:53 CET, in the user unit `g1-main`. The lock is released.
The earlier, blocked CPU-only report is kept as `g1-result-blocked-cpu.md`.

## Deviations from the doc (stated, not hidden)
- **Run from asus, not acer.** I ran against asus's own LAN address, 192.168.10.113, which loopback reaches. Client-side wall times therefore have no LAN hop. Ollama's own timings (TTFT, decode) are unaffected.
- **No msi row.** msi's Ollama admits acer only, so it is unreachable from asus. The G1 decode bar therefore falls back to the table's `>= 24 tok/s` rule, not 5× msi.
- **Extra VRAM-log columns:** utilisation.gpu, temperature.gpu and power.draw. The table reads its columns by name.
- **`import-g1` output:** written to the state dir, not into `pkgs/llm-bench/scorecard`. Nothing was committed.

## Exact commands (driver `~/.cache/g1-run/bin/g1-main.sh`)
```
systemd-run --user --collect --unit=g1-main -p StandardOutput=file:$R/run.log -p StandardError=file:$R/run.log \
  flock -o /run/work-locks/heavy-work.lock ~/.cache/g1-run/bin/g1-main.sh        # R=~/.local/state/fleet-lead/g1-run2
nvidia-smi --query-gpu=timestamp,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv -lms 1000 > $R/g1/vram-asus.csv &
for m in qwen2.5-coder:7b-instruct-q4_K_M gemma4:e4b-it-qat gemma4:e2b-it-qat; do for c in 4096 8192; do
  scripts/ollama-g1-bench.sh 192.168.10.113 "$m" "$c" 5 20 $R/g1/g1-asus-"${m//:/_}"-"$c".jsonl
  OLLAMA_HOST=192.168.10.113:11434 ollama ps; curl -s 192.168.10.113:11434/api/ps      # -> $R/ps/
done; done
for m in ...same three...; do
  nix run .#llm-bench -- capacity --base http://192.168.10.113:11434/v1 --host asus-b460m --model "$m" --ctx 4096 --route direct --out $R/capacity
done
journalctl -u ollama --since <start> > $R/ollama-journal.log
python3 scripts/ollama-g1-table.py $R/g1
nix run .#llm-bench -- import-g1 --src $R/g1 --out $R/scorecard
nix run .#llm-bench -- table $R/scorecard/*.json $R/capacity/*[0-9].json
```

Raw output is in `~/.local/state/fleet-lead/g1-run2/`:
- `g1/*.jsonl`: one line per request;
- `g1/vram-asus.csv`: 1 Hz GPU log;
- `capacity/*.json`: aggregates, plus `*.runs.jsonl` per turn (never commit those);
- `ps/`: `ollama ps` and `/api/ps` after each run;
- `ollama-journal.log`;
- `g1-table.md`, `llm-bench-table.md` and `run.log`.

## State and GPU proof
- **Ollama** was restarted at 10:46:32 after the #506 deploy. Its journal shows `inference compute ... library=CUDA compute=8.6 description="NVIDIA GeForce RTX 3070" total="7.6 GiB"`.
- **Pins:** all three tags are present at their pinned digests (`/api/tags`).
- **It really ran on the GPU, per model.**
  - `ollama ps` showed `100% GPU` in every snapshot: 6 G1 runs and 3 capacity runs.
  - The journal has 33 model loads during the run, 11 per model, each with every layer on the GPU and **no CPU model buffer**:

| model | layers offloaded | CUDA0 model buffer |
|---|---|---|
| qwen2.5-coder:7b-instruct-q4_K_M | 29/29 | 4168 MiB |
| gemma4:e4b-it-qat | 43/43 | 2696 MiB |
| gemma4:e2b-it-qat | 36/36 | 1342 MiB |

  - `gpu_share` is 1 on every request.
- **GPU while serving** (warm runs, from vram-asus.csv):

| model | utilisation p50 | temperature max | power p50 |
|---|---|---|---|
| qwen2.5-coder | 97–98 % | 86 °C | about 255 W |
| gemma4:e4b | 94–95 % | 84 °C | about 215 W |
| gemma4:e2b | 91–92 % | 80 °C | about 195 W |

  No thermal limit was hit within the 270 W cap.

## G1 table (`scripts/ollama-g1-table.py`, as rendered)
| host | model | ctx | clients | n cold/warm | VRAM load MiB | VRAM steady MiB | headroom MiB | gpu_share min | decode tok/s p50 | TTFT p50/p95 s | TTFT queued p95 s | cold load p50 s | G1 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 192.168.10.113 | gemma4:e2b-it-qat | 4096 | 1 | 5/20 | 4285 | 2861 | 5331 | 1 | 148.3 | 0.41/0.41 (n 20) | 0.45 | 2.50 | pass |
| 192.168.10.113 | gemma4:e2b-it-qat | 8192 | 1 | 5/20 | 3013 | 3013 | 5179 | 1 | 143.3 | 0.74/0.75 (n 20) | 0.80 | 2.50 | pass |
| 192.168.10.113 | gemma4:e4b-it-qat | 4096 | 1 | 5/20 | 4247 | 4247 | 3945 | 1 | 87.7 | 0.68/0.70 (n 20) | 0.76 | 2.77 | pass |
| 192.168.10.113 | gemma4:e4b-it-qat | 8192 | 1 | 5/20 | 4285 | 4285 | 3907 | 1 | 85.0 | 1.28/1.33 (n 20) | 1.42 | 2.80 | pass |
| 192.168.10.113 | qwen2.5-coder:7b-instruct-q4_K_M | 4096 | 1 | 5/20 | 4639 | 4639 | 3553 | 1 | 75.4 | 0.76/0.80 (n 20) | 0.86 | 1.98 | pass |
| 192.168.10.113 | qwen2.5-coder:7b-instruct-q4_K_M | 8192 | 1 | 5/20 | 4909 | 4909.0 | 3283 | 1 | 71.7 | 1.47/1.50 (n 20) | 1.63 | 1.99 | pass |

- **Prompt size:** about 2.5–2.9K tokens at 4096 and 4.8–5.4K at 8192. Prefill p50 ran at 3.3K tok/s (qwen), 4.2K (e4b) and 7.1–7.3K (e2b).
- **Table quirk:** the gemma4:e2b 4096 "VRAM load" of 4285 MiB includes the previous model (e4b, still resident with keep_alive 10m) during its swap-out. e2b's own footprint is its steady 2861 MiB.
- **Formatting nit:** the qwen 8192 steady value prints as `4909.0`; that is the table script's formatting.

## Agent capacity (`llm-bench capacity`, Pi-shaped streamed /v1 turns, ctx 4096 loaded, `thresholds.json` capacity)

**qwen2.5-coder:7b-instruct-q4_K_M: 2 agents**, with 20–21 requests per level.

| agents | TTFT p50 s | TTFT p95 s | decode tok/s per agent p50 | queue wait p95 s (est.) | turn time p50 s |
|---|---|---|---|---|---|
| 1 | 0.76 | 0.80 | 75.8 | 0.00 | 1.55 |
| 2 | 2.32 | 2.58 | 75.7 | 1.78 | 3.08 |
| 3 | 4.04 | 4.34 | 76.0 | **3.53 > 3.0** | 4.84 |

The run stopped at level 3, because its queue wait exceeds `queue_wait_p95_s_max` 3.0.

**gemma4:e4b-it-qat and gemma4:e2b-it-qat: not evaluable (agents = null).** Over `/v1/chat/completions`, both thinking models spent the whole `max_tokens` budget of 128 on reasoning. All 20 turns at N=1 are `reasoning_only`, with no content token, so there is no content TTFT and `within()` returns None.
- First output (reasoning) at N=1: p50 0.70 s for e4b and 0.43 s for e2b.
- Decode over the whole turn: 62 tok/s for e4b and 102 tok/s for e2b.
- This is a fixture/model mismatch, not a GPU limit. A gemma4 capacity number needs thinking off for agent turns (Ollama `think: false` / `reasoning_effort`) or a larger `max_tokens`. That is a change to llm-bench, which is the owner's call; I did not change it.

## Conclusions (numbers above)
1. **Which models fit the card: all three, fully on the GPU, at both 4096 and 8192.**
   - Headroom is at least 3283 MiB in every row against the 768 MiB gate. qwen at 8192 is the tightest (4909 MiB steady); gemma4:e2b is the lightest (2861–3013 MiB).
   - All six one-client rows pass G1: every layer is on the GPU, and decode is 71.7–148.3 tok/s against the 24 floor.
   - Cold load is 2.0–2.8 s p50, with 8 GB of VRAM leaving room for only one of these models at a time (`OLLAMA_MAX_LOADED_MODELS=1` anyway).
2. **Concurrency: tokens/s per request never halves; latency is what degrades.**
   - With `OLLAMA_NUM_PARALLEL=1`, requests queue, so per-agent decode stays flat (75.8 → 75.7 → 76.0 tok/s for qwen at N = 1/2/3).
   - Each added closed-loop agent adds about one turn's service time (about 1.55–1.75 s for a 128-token turn) to TTFT.
   - So the "per-request tok/s halves" criterion from the original brief is never reached. The binding limit is queue wait and TTFT: qwen sustains 2 agents under the current thresholds.
3. **Could not measure:**
   - gemma4 agent capacity, because of thinking mode (above);
   - the 5× msi decode bar (msi is unreachable from asus);
   - an 8K capacity run (the server loads 4096; the doc says so);
   - batching with `OLLAMA_NUM_PARALLEL` > 1, which is a config change and out of scope here.

## Proposal: "decent performance" per Pi agent (for the owner; a proposal, not a decision)
These are proposed for `pkgs/llm-bench/thresholds.json` `capacity`. A closed-loop agent that never pauses is the worst case. Real Pi agents spend part of each turn on tool execution, so they load the queue less than the measured N.

| metric | current (proposed) | my proposal | reasoning from the numbers |
|---|---|---|---|
| TTFT p95 per turn, queue included, at 4K | 5.0 s | **3.0 s** | A single agent sees 0.4–0.8 s, so 3 s leaves room for about 2 queued turns. Above about 3 s an interactive agent loop feels stalled, and with qwen 3 s is crossed exactly at N=3 (4.34 s). At 5 s, qwen would sustain 3 agents with TTFT 5.4× its idle value. |
| TTFT p95 at 8K | n/a | **5.0 s** | Prefill doubles at 8K (qwen 0.80 → 1.50 s p95 idle), so the same queue headroom of about 2 turns lands near 5 s. |
| decode tok/s per agent p50 | 10 | **25** | Every model does 62–148 tok/s, and with NUM_PARALLEL=1 that never drops under load, so 10 can never bind. 25 is about the G1 floor (24) and keeps a 256-token answer under about 10 s. It would only bind if batching (NUM_PARALLEL > 1) is later turned on to trade per-agent speed for throughput. |
| queue wait p95 (estimated) | 3.0 s | **2.5 s** (or drop it and keep TTFT only) | With NUM_PARALLEL=1, queue wait ≈ TTFT p95 − idle TTFT p95, so it is redundant with the TTFT limit. 2.5 s keeps the two consistent at 4K (0.8 + 2.5 ≈ 3.3). |
| concurrent sessions | derived | **qwen2.5-coder: 2 per asus**; gemma4: after a thinking-off re-run | At 2 agents qwen's TTFT p95 is 2.58 s and decode 75.7 tok/s. At 3 it is 4.34 s. |

Estimate only, not measured: gemma4:e2b at about 1.25 s per turn should sustain about 3 agents and e4b (about 2.07 s per turn) about 2, once it emits content.

A further lever, for the owner: `OLLAMA_NUM_PARALLEL=2` with 3–5 GB of VRAM headroom could batch two agents. A measurement after that change would tell whether it beats queueing.
