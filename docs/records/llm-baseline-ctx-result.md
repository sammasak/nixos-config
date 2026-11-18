# Context length and long Pi sessions on asus-b460m at 130 W, 2026-11-17

The GPU is an RTX 3070 8 GB, with driver 595.104.02 and Ollama 0.40.3 (CUDA). The server config is untouched: `OLLAMA_CONTEXT_LENGTH=4096`, `NUM_PARALLEL=1`, flash attention on, KV cache q8_0.
`power.limit` read 130.00 W before every request in the ceiling run (the script stops otherwise) and before each session. The log shows 130 W throughout.
Each measured part held `/run/work-locks/heavy-work.lock`. Nothing was committed or changed for this part, and there was no service or Ollama config change.

## 1. Context ceiling per model

Method:
- one cold and one warm `/api/generate` per `num_ctx`, with `options.num_ctx` set per request;
- the prompt is repo code filling about 80 % of the context, with a nonce first so the warm run is not served from cache;
- `num_predict` 128, `think: false`;
- VRAM is the nvidia-smi peak during the warm request;
- GPU share is from `/api/ps`, and every load's journal line says `offloaded 29/29` (qwen), `43/43` (e4b) or `36/36` (e2b) layers to the GPU, with zero CPU model buffers.

| model | num_ctx asked | ctx loaded | prompt tokens (fill) | GPU | VRAM MiB | headroom MiB | prefill tok/s | TTFT cold s | TTFT warm s | decode tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| qwen2.5-coder:7b | 4096 | 4096 | 2844 (69 %) | 100 % | 4639 | 3553 | 2644 | 3.1 | 1.1 | 72 |
| qwen2.5-coder:7b | 8192 | 8192 | 6458 (79 %) | 100 % | 4909 | 3283 | 2673 | 4.4 | 2.4 | 67 |
| qwen2.5-coder:7b | 16384 | 16384 | 13367 (82 %) | 100 % | 5007 | 3185 | 2271 | 7.8 | 5.9 | 57 |
| qwen2.5-coder:7b | 32768 | 32768 | 25171 (77 %) | 100 % | 5499 | 2693 | 1930 | 14.9 | 13.0 | 42 |
| qwen2.5-coder:7b | 65536 | **32768** | 16386 (truncated) | 100 % | 5499 | 2693 | (cache) | 9.5 | 0.0 | 51 |
| qwen2.5-coder:7b | 131072 | **32768** | 16386 (truncated) | 100 % | 5499 | 2693 | (cache) | 9.6 | 0.0 | 51 |
| gemma4:e4b | 4096 | 4096 | 3192 (78 %) | 100 % | 4247 | 3945 | 3584 | 7.6 | 0.9 | 85 |
| gemma4:e4b | 8192 | 8192 | 6353 (78 %) | 100 % | 4285 | 3907 | 3609 | 5.9 | 1.8 | 80 |
| gemma4:e4b | 16384 | 16384 | 13340 (81 %) | 100 % | 4393 | 3799 | 3430 | 7.7 | 3.9 | 74 |
| gemma4:e4b | 32768 | 32768 | 25453 (78 %) | 100 % | 4609 | 3583 | 3121 | 11.0 | 8.2 | 62 |
| gemma4:e4b | 65536 | 65536 | 53799 (82 %) | 100 % | 5041 | 3151 | 2536 | 24.1 | 21.2 | 48 |
| gemma4:e4b | 131072 | 131072 | 102983 (79 %) | 100 % | 5905 | 2287 | 1919 | 56.7 | 53.7 | 33 |
| gemma4:e2b | 4096 | 4096 | 3192 (78 %) | 100 % | 2861 | 5331 | 6184 | 6.5 | 0.5 | 137 |
| gemma4:e2b | 8192 | 8192 | 6354 (78 %) | 100 % | 3013 | 5179 | 6203 | 4.8 | 1.0 | 135 |
| gemma4:e2b | 16384 | 16384 | 13338 (81 %) | 100 % | 3055 | 5137 | 5839 | 5.6 | 2.3 | 121 |
| gemma4:e2b | 32768 | 32768 | 25452 (78 %) | 100 % | 3137 | 5055 | 5116 | 8.4 | 5.0 | 104 |
| gemma4:e2b | 65536 | 65536 | 53801 (82 %) | 100 % | 3303 | 4889 | 3916 | 17.0 | 13.7 | 83 |
| gemma4:e2b | 131072 | 131072 | 102981 (79 %) | 100 % | 3571 | 4621 | 2607 | 42.9 | 39.5 | 61 |

- **Largest context that stays 100 % on the GPU with at least 768 MiB headroom:** qwen2.5-coder 32768 (2693 MiB headroom), and gemma4:e4b and e2b 131072, their maximum (2287 and 4621 MiB). Nothing spilled to the CPU and nothing failed. On this card, memory is never the limit; latency is.
- **qwen above 32768 silently truncates.** Ollama clamps to the trained 32768 and evaluates only 16386 tokens of the prompt, keeping its tail, with no error. The warm repeat is then a full cache hit, which is why its TTFT is 0.0. Never ask qwen for more than 32K.
- **Cold TTFT includes the model load.** For the first row of each model that load includes swapping out the previous model. The warm column is what a cache-missed turn costs.
- **The VRAM peaks are 0.5 s samples.** KV is q8_0, and gemma4's sliding-window layers keep its KV small: 128K costs e4b only about 1.7 GB more than 4K.

## 2. Long Pi-shaped sessions (streamed `/api/chat`, `options.num_ctx`, tools defined, temperature 0)

Each turn adds an assistant tool call and its result: a numbered file read of 100–300 lines, or, every third turn, a grep of up to 40 lines. The model's real streamed reply stays in the history, with `num_predict` 160.
"Context" is Ollama's `prompt_eval_count`, which on this version reports the full prompt even when the KV cache serves most of it. TTFT is client-side, to the first streamed token.

| | qwen2.5-coder:7b @ 32768 | gemma4:e4b @ 65536, `think: false` |
|---|---|---|
| turns run | 30 (219 s total) | 53 (512 s total) |
| first turn (cold load) TTFT | 3.2 s | 6.8 s |
| **before the limit: TTFT p50 / max** | **0.80 / 2.27 s** | **0.80 / 2.17 s** |
| before the limit: turn time p50 / max | 3.7 / 6.3 s | 3.5 / 5.7 s |
| decode: start → just before the limit | 70 → 37 tok/s | 86 → 44 tok/s |
| limit reached | turn 22, at 32605 tokens | turn 39, at 63727 tokens |
| **after the limit: turns that re-read everything** | **5 of 8, TTFT p50 18.8 s, turn p50 22 s** | **12 of 14, TTFT p50 30.6 s, turn p50 33 s** |
| replies near and after the limit | repeat themselves (turns 21 and 29 identical) | repeat themselves (turns 38 and 52 identical); turn 46 hit 65535 tokens and produced 1 token |

Per-turn rows are in `session-*.jsonl`.

What happened:
- **The prompt cache holds** as long as the history only grows. The TTFT jumps track the new tokens only: a grep turn costs 0.04–0.4 s, and a 300-line read 1–2.3 s. A full re-read at the same size would take 11 s for qwen at 22K, or 21 s for e4b at 54K.
- **At the limit, Ollama drops the oldest messages to fit** (journal: `truncated = 1`). That changes the prefix, so the cache misses and nearly every later turn re-reads the whole window: about 19 s for qwen at 32K, about 31 s for e4b at 64K. There is no error. Turns just get 6–10× slower, and the model starts looping.
- **Decode slows as context grows,** roughly halving from an empty context to a full one. Even full, it stays at 37 tok/s or more, so a 160-token reply takes about 4 s.

## 3. Real `pi` session

`pi` 1.2.0 is installed (`/etc/profiles/per-user/lukas/bin/pi`). It reaches Ollama only through `/v1` (`api: openai-completions`).

**Blocker for long `pi` sessions today:** `/v1` ignores `num_ctx`. I tested `options.num_ctx` and top-level `num_ctx`, and both leave `context_length` at 4096. So `pi` runs at the server's `OLLAMA_CONTEXT_LENGTH=4096`, and `pi`'s own system prompt and tools take about 2.5K of it. Raising it is a one-line asus config change, which is the owner's call: `services.ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH = "32768"`.
- It costs at most 5.5 GB of VRAM (qwen) or 4.6 GB (e4b) per load, measured above.
- Note: the G1 gate's comment says 4096 is "the G1 headroom gate's context", and the bench passes `num_ctx` explicitly, so G1 is unaffected.

Two proof sessions, each a short `pi -p` run against asus's Ollama in a scratch repo where `calc.py`'s `add` subtracts:
- **qwen2.5-coder:7b: failed.** It answered with the tool call as JSON text, `{"name": "read", …}`, not a structured `tool_calls`, so `pi` printed it and stopped after 5.2 s with the bug unfixed. Output: `pi-qwen-4096.txt`.
- **gemma4:e4b with `--thinking off`: worked.**
  - It made 6 `/v1` calls: read, edit, then ran the test, which printed `ok`. `git diff` shows `return a + b`.
  - Total 15.1 s. The first call took 9.1 s, including swapping qwen out and a 2.6K-token first prompt; the follow-ups took 0.7–2.1 s.
  - Context grew from 2651 to 3293 tokens of the 4096 in that tiny task. Output: `pi-e4b-4096.txt`.

**Try it.** Run it on asus itself or on acer; asus's Ollama admits only acer and loopback. The scratch agent directory leaves `~/.pi` untouched:

```
mkdir -p ~/pi-asus && cat > ~/pi-asus/models.json <<'EOF'
{ "providers": { "asus-ollama": {
    "baseUrl": "http://192.168.10.113:11434/v1", "api": "openai-completions", "apiKey": "ollama",
    "models": [ { "id": "gemma4:e4b-it-qat", "contextWindow": 4096, "maxTokens": 2048, "reasoning": true } ] } } }
EOF
cd ~/some-repo && PI_CODING_AGENT_DIR=~/pi-asus pi --model asus-ollama/gemma4:e4b-it-qat --thinking off
```

- **`contextWindow` must equal the server's context:** 4096 today, 32768 after the owner's change. A larger value lets `pi` overfill, and Ollama then truncates silently, with the slow, looping turns from section 2.
- **Compaction:** with a correct `contextWindow`, `pi`'s own compaction should trigger before Ollama truncates. I did not verify that.

## 4. Noise and heat in real use at 130 W

From `gpu-b2.csv`, 731 one-second samples over both long sessions, at 99 % utilisation (p50):

| power draw | temperature | fan | VRAM |
|---|---|---|---|
| 130 W p50 and p95, 132 W max | p50 59 °C, max 61 °C | **67 % flat** | p50 5.0 GB, max 5.5 GB |

That's the coordinator's 130 W row (60 °C, 70 %), now confirmed under real agent load, against 100 % fan at 270 W.

## Recommendation for longer `pi` sessions
**gemma4:e4b-it-qat, thinking off, at 32768 context.** This needs the owner's `OLLAMA_CONTEXT_LENGTH = "32768"` change, plus `contextWindow: 32768` in `pi`.
- **It is the only pinned model that works as a `pi` agent.** qwen2.5-coder doesn't emit structured tool calls through `/v1`, and the gemma4 models need thinking off or they spend their tokens on reasoning (G1 capacity run).
- **At 32K, every turn inside the window feels fast:**
  - a TTFT of about 0.1–2 s on cached turns;
  - decode of 62 tok/s or more, which is 160 tokens in under 3 s;
  - the worst case is a full re-read after a cache miss, 8–11 s;
  - 4.6 GB of VRAM leaves 3.5 GB of headroom.
- **64K roughly doubles the bad case, so it suits only "read a lot once" sessions.** Cached turns are still about 1–2 s, but a cache miss costs 21–24 s, and every turn past the limit about 31 s. 128K fits the card but costs 54 s per miss and 33 tok/s.
- **gemma4:e2b is the speed option:**
  - at 32K, a full re-read takes 5 s with decode at 104 tok/s;
  - its per-turn numbers are about 40 % lower than e4b's;
  - I didn't test it with `pi` or judge its answer quality.

## What feels fast and what doesn't (measured)
**Fast:**
- a new turn after a grep or a short tool result: 0.04–0.4 s to the first token;
- after a 100–300 line file read: 0.6–2.3 s;
- a whole agent step of 160 tokens: 2–6 s;
- a small `pi` fix: 15 s end to end, where the first call's 9 s is the model load.

**Slow:**
- the first turn after a model swap: 6–9 s;
- any cache miss on a full window: 13 s for qwen at 32K, 8 s for e4b at 32K, 21 s for e4b at 64K;
- every turn after the context limit: 19–34 s, with replies starting to repeat;
- a `pi` session left at today's 4096 context: it hits the limit within a few file reads.

## Raw output: `~/.local/state/fleet-lead/ctx-run/`
- `ceiling.jsonl`, `b1.log`, `gpu-b1.csv`, `ollama-journal-b1.log`: section 1;
- `session-qwen-32768.jsonl`, `session-e4b-65536.jsonl`, `b2.log`, `gpu-b2.csv`, `ollama-journal-b2.log`: sections 2 and 4;
- `pi-qwen-4096.txt`, `pi-e4b-4096.txt`: section 3;
- scripts: `~/.cache/g1-run/bin/ctx_ceiling.py`, `long_session.py`, `ctx-b1.sh`, `ctx-b2.sh`;
- scratch `pi` config and repo: `~/.cache/pi-scratch/`.

## Could not measure
- **A long real `pi` session:** blocked on the server's 4096 context until the owner raises it. The 30- and 53-turn sessions are faithful simulations through the native API, not `pi`.
- **Whether `pi`'s compaction triggers before Ollama truncates,** with a correct `contextWindow`.
- **Answer quality.** The simulated tool results are scripted, so they don't follow the model's requests; the repetition near the limit is the only quality signal.
- **gemma4:e2b in a long session or with `pi`.**
- **Prefill speed at 270 W.** The G1 numbers were at 270 W and these are at 130 W, so the two tables differ by the cap as well as by method.
