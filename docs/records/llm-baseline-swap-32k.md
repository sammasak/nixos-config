# asus-b460m: model swap at a 32K context, qwen2.5-coder ↔ gemma4:e4b (evidence for #512)

Measured on asus-b460m on 17 Nov 2026, 14:43:13–14:44:01 CET, holding `/run/work-locks/heavy-work.lock`. The GPU was the RTX 3070 at `power.limit` 130.00 W, `memory.total` 8192 MiB and `memory.reserved` 359 MiB, so 7833 MiB is usable. Ollama 0.40.3 CUDA ran with `OLLAMA_MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`, flash attention and KV q8_0.

**How 32K was reached:** the live server still runs `OLLAMA_CONTEXT_LENGTH=4096` (#512 is not deployed), and `/v1` drops `num_ctx`. So this run cannot go through `/v1` at the server's 32K. Instead, every request went to `/api/chat` with `options.num_ctx` 32768, which loads the model at exactly the context #512 would make the server default. No service or config change was made.

## What was run
```
flock -o /run/work-locks/heavy-work.lock \
  python3 -I ~/.cache/g1-run/bin/swap32k_chat.py ~/.local/state/fleet-lead/ctx-run/corpus.txt ~/.local/state/fleet-lead/swap32k-chat
journalctl -u ollama --since "2026-11-17 14:43:13" --until "2026-11-17 14:44:01" -o short-precise
```
- **Sequence:** qwen2.5-coder:7b-instruct-q4_K_M → gemma4:e4b-it-qat → qwen → e4b, so both directions run twice.
- **Each request:** `/api/chat`, `stream:false`, `think:false`, `keep_alive:"10m"`, `options:{num_ctx:32768, num_predict:32, temperature:0, seed:42}`, with a system message and a user message carrying about 66K characters of repo code (18.6K tokens for qwen, 20.8K for e4b).
- **A sampler thread recorded every 0.2 s for the whole window (209 samples):** `nvidia-smi` `memory.used`, the `/api/ps` models (name, size, size_vram, context_length), and the running `llama-server` processes (PID and model blob).
- **After each request:** `/api/ps` and `ollama ps`.

## Result per step

| step | model | runner (PID, blob) | evicted before it started | `/api/ps` after the load | `ollama ps` | load | VRAM peak in the step |
|---|---|---|---|---|---|---|---|
| 0 | qwen2.5-coder | 438994, sha256-60e05f21… | (nothing resident) | only qwen, `context_length` 32768, `size_vram` 5540864326 == `size` 5540864326 | 5.5 GB, **100% GPU**, 32768 | 2.17 s | 5499 MiB |
| 1 | gemma4:e4b | 439286, sha256-e8b6a059… | qwen's runner 438994 gone at 14:43:26.2; VRAM 9 MiB; `/api/ps` empty | only e4b, 32768, `size_vram` 3197947083 == `size` | 3.2 GB, **100% GPU**, 32768 | 3.75 s | **4609 MiB** |
| 2 | qwen2.5-coder | 439552, sha256-60e05f21… | e4b's runner 439286 gone at 14:43:37.0; VRAM 9 MiB; `/api/ps` empty | only qwen, 32768, `size_vram` == `size` | 5.5 GB, **100% GPU**, 32768 | 2.90 s | 5499 MiB |
| 3 | gemma4:e4b | 439860, sha256-e8b6a059… | qwen's runner 439552 gone at 14:43:49.4; VRAM 9 MiB; `/api/ps` empty | only e4b, 32768, `size_vram` == `size` | 3.2 GB, **100% GPU**, 32768 | 3.94 s | **4609 MiB** |

Across all 209 samples:
- `/api/ps` never listed more than one model, and there was never more than one model runner.
- VRAM never exceeded 5499 MiB. In the steps that load e4b after qwen, the peak is e4b's own 4609 MiB. So qwen's 5.5 GB was fully released before e4b allocated anything: no overlap and no spill.
- Between the old runner exiting and the new model's runner starting, the samples show short-lived `llama-server` processes with no model blob, at most 171 MiB of VRAM each. These are Ollama's device-discovery probes before a load.

**How eviction shows:** Ollama 0.40.3 logs no explicit unload line at INFO. The eviction is shown by the old runner's PID exiting, VRAM falling to 9 MiB and `/api/ps` going empty. Then, at the next load, the scheduler line reports the full card free: `free="7.5 GiB"`. With qwen still resident it would have read about 2.1 GiB.

Sampler transitions, verbatim from `samples.jsonl`:
```
14:43:16.6 mem 5499 runners [(438994, 'sha256-60e05f210007')] ps [qwen2.5-coder:7b-instruct-q4_K_M, size_vram==size, 32768]
14:43:26.2 mem 9    runners []                                 ps []
14:43:27.8 mem 9    runners [(439286, 'sha256-e8b6a059ba86')] ps []
14:43:29.8 mem 4581 runners [(439286, 'sha256-e8b6a059ba86')] ps [gemma4:e4b-it-qat, size_vram==size, 32768]
14:43:37.0 mem 9    runners []                                 ps []
14:43:38.5 mem 9    runners [(439552, 'sha256-60e05f210007')] ps []
14:43:39.8 mem 5499 runners [(439552, 'sha256-60e05f210007')] ps [qwen2.5-coder:7b-instruct-q4_K_M, size_vram==size, 32768]
14:43:49.4 mem 9    runners []                                 ps []
14:43:51.2 mem 9    runners [(439860, 'sha256-e8b6a059ba86')] ps []
14:43:53.2 mem 4581 runners [(439860, 'sha256-e8b6a059ba86')] ps [gemma4:e4b-it-qat, size_vram==size, 32768]
```

## Journal lines for each load (`journalctl -u ollama`, abridged to the lines that matter)
```
14:43:15.217 msg="starting llama-server"                                   # step 0, qwen
14:43:15.218 msg="gpu memory" id=0 library=CUDA available="7.0 GiB" free="7.5 GiB"
14:43:15.807 load_tensors: offloaded 29/29 layers to GPU
14:43:15.807 load_tensors:   CPU_Mapped model buffer size =   292.36 MiB
14:43:15.807 load_tensors:        CUDA0 model buffer size =  4168.09 MiB
14:43:16.203 llama_context: n_ctx_seq = 32768
14:43:16.204 llama_kv_cache: CUDA0 KV buffer size = 952.00 MiB
14:43:16.219 sched_reserve:  CUDA0 compute buffer size = 164.09 MiB
14:43:16.474 msg="loaded runners" count=1

14:43:27.783 msg="starting llama-server"                                   # step 1, e4b after qwen
14:43:27.784 msg="gpu memory" id=0 library=CUDA available="7.0 GiB" free="7.5 GiB"
14:43:28.992 load_tensors: offloaded 43/43 layers to GPU
14:43:28.992 load_tensors:   CPU_Mapped model buffer size =  2730.00 MiB
14:43:28.992 load_tensors:        CUDA0 model buffer size =  2696.06 MiB
14:43:29.260 llama_context: n_ctx_seq = 32768
14:43:29.260 llama_kv_cache: CUDA0 KV buffer size = 272.00 MiB
14:43:29.261 llama_kv_cache: CUDA0 KV buffer size =  21.25 MiB
14:43:29.282 sched_reserve:  CUDA0 compute buffer size = 231.30 MiB
14:43:29.791 msg="loaded runners" count=1

14:43:38.496 msg="starting llama-server"                                   # step 2, qwen after e4b
14:43:38.497 msg="gpu memory" id=0 library=CUDA available="7.0 GiB" free="7.5 GiB"
14:43:39.065 load_tensors: offloaded 29/29 layers to GPU
14:43:39.065 load_tensors:   CPU_Mapped model buffer size =   292.36 MiB
14:43:39.065 load_tensors:        CUDA0 model buffer size =  4168.09 MiB
14:43:39.459 llama_context: n_ctx_seq = 32768
14:43:39.460 llama_kv_cache: CUDA0 KV buffer size = 952.00 MiB
14:43:39.476 sched_reserve:  CUDA0 compute buffer size = 164.09 MiB
14:43:39.750 msg="loaded runners" count=1

14:43:51.222 msg="starting llama-server"                                   # step 3, e4b after qwen
14:43:51.222 msg="gpu memory" id=0 library=CUDA available="7.0 GiB" free="7.5 GiB"
14:43:52.444 load_tensors: offloaded 43/43 layers to GPU
14:43:52.444 load_tensors:   CPU_Mapped model buffer size =  2730.00 MiB
14:43:52.444 load_tensors:        CUDA0 model buffer size =  2696.06 MiB
14:43:52.712 llama_context: n_ctx_seq = 32768
14:43:52.713 llama_kv_cache: CUDA0 KV buffer size = 272.00 MiB
14:43:52.714 llama_kv_cache: CUDA0 KV buffer size =  21.25 MiB
14:43:52.734 sched_reserve:  CUDA0 compute buffer size = 231.30 MiB
14:43:53.233 msg="loaded runners" count=1
```

## About the CPU buffer: present, fixed, not a spill
The review asked for "no CPU model buffer". Literally, each load **does** map a host-memory model buffer: `CPU_Mapped` 292.36 MiB for qwen and 2730.00 MiB for e4b. It is not a context or swap effect:
- **The sizes don't move with context.** They are byte-identical at num_ctx 4096, 8192, 16384, 32768, 65536 and 131072 (G1 and ctx-run journals, 17 Nov), and at every load here.
- **Every layer is offloaded** (`offloaded 29/29`, `43/43`), with the KV and compute buffers on CUDA0.
- **Ollama counts the model as fully resident:** `/api/ps` `size_vram == size`, and `ollama ps` shows `100% GPU`.
- **What it is, inferred:** the log doesn't name these tensors. That they are the input-embedding tables, which llama.cpp keeps in host memory, and for gemma4's e-models the per-layer embeddings, is my inference.
- This corrects my earlier #492 statement of "no CPU model buffer", which came from a grep that missed the `CPU_Mapped` spelling. The timings were never affected.

## Against the host comment in #512
The comment reads: "At 32K each pinned tag stays fully on the GPU, also right after a swap: qwen 5499 MiB, gemma4:e4b 4609, of the 7833 the driver leaves usable (8192 less 359 reserved)." The measured steady VRAM is qwen 5499 MiB and e4b 4609 MiB in both directions, and the usable total is 8192 − 359 = 7833 MiB, confirmed by `nvidia-smi` at the start of the run. **No number contradicts the comment, so no new commit.** Headroom after a swap: qwen 2334 MiB, e4b 3224 MiB.

## Raw files (on asus-b460m)
- `~/.local/state/fleet-lead/swap32k-chat/samples.jsonl`: the 0.2 s sampler, 209 lines;
- `~/.local/state/fleet-lead/swap32k-chat/steps.jsonl`: per request, with `/api/ps` and the `ollama ps` text;
- `~/.local/state/fleet-lead/swap32k-chat/run.log`;
- `~/.local/state/fleet-lead/swap32k-chat/ollama-journal.log`: the full journal for the window, 1600 lines;
- the script: `~/.cache/g1-run/bin/swap32k_chat.py`.

An earlier run of the same sequence on `/api/generate` (13:52:00–13:52:45, sampling inside each request only) gave the same numbers: `ctx-run/swap32k.jsonl` and `ctx-run/ollama-journal-swap.log`.

## What this does not prove (deploy only)
- **The same swap through `/v1` once the server default is 32768.** The load path is the same; only the source of `num_ctx` differs. After deploy: alternate two `/v1` requests and repeat the `/api/ps` and `ollama ps` check.
- **Behaviour with a `pi` session's KV cache filled to 32K at swap time.** The KV buffer is allocated at load for the full `n_ctx_seq`, so fill does not change VRAM, but that is inferred from the buffer sizes, not observed.
