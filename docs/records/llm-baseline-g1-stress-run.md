# #492 G1: 30-minute one-request stress run on asus-b460m, 18 Nov 2026

**Setup:**
- **System:** asus-b460m as deployed at main a93c2385 (`/run/current-system` yql123dp…), RTX 3070 8 GiB, cap 130 W, persistence on.
- **Ollama:** 0.40.3 CUDA as deployed: `NUM_PARALLEL=1`, `MAX_LOADED_MODELS=1`, `OLLAMA_CONTEXT_LENGTH=32768`, service `MemoryMax=8G`. Unchanged: no config, service or threshold changes.
- **Model:** `qwen2.5-coder:7b-instruct-q4_K_M` (Q4_K_M, digest dae161e2…), resident at the request's `num_ctx` 4096.
- **Load scenario declared:** desktop idle. asus runs no graphical session; load average 0.18 before the run, no worker containers running.
- **Tool:** `scripts/ollama-g1-bench.sh` from a fresh worktree at a93c2385 (docs/local-inference-bench.md).
- **Monitoring:** nvidia-smi at 1 Hz, `/proc/meminfo` MemAvailable at 1 Hz, then the kernel and `ollama` journals for the window.
- **Lock:** `/run/work-locks/heavy-work.lock` held throughout.

## Two runs, and why
1. **Run 1** (14:42:26–15:12:41, 30 min 15 s; `g1-stress-r1-cachedrepeats/`): 23 back-to-back bench invocations of 20 warm requests each, 484 requests in total.
   - **My mistake:** each invocation restarts the bench's per-request nonce (`Run warm-<i>-1`), so invocations 2–23 repeated invocation 1's 20 prompts exactly. llama-server served those from its prompt cache, at 0.016 s TTFT instead of about 0.95 s.
   - **So:** run 1's TTFT and its load are not a valid one-request stress. Its decode, VRAM and stability readings are valid for its window.
2. **Run 2** (15:14:37 onward; `g1-stress/`): **one** bench invocation, 1 cold + 400 warm, so every prompt is distinct. This is the valid stress. **It ended after 7 min 38 s:** the kernel OOM-killed `llama-server` inside `ollama.service`'s memory cgroup (below).

## Results

| measurement | value | source |
|---|---|---|
| requests completed | run 2: **98** (1 cold, 1 warm-up, 96 warm) in 455 s, then killed; run 1: 484 in 1813 s (prompts repeated) | bench JSONL |
| decode tok/s, warm | run 2: **p50 70.0**, p5 69.8, p95 70.5 (min 69.7, max 70.6); run 1: p50 69.8, p5 69.3, p95 70.0 | Ollama `eval_count / eval_duration` |
| TTFT, warm (load + prompt eval, 2521 prompt tokens) | run 2: **p50 0.949 s, p95 0.968 s**, max 1.004 s; client-side TTFT with queue p95 1.03 s | bench JSONL |
| GPU share | 1.0 on every request (size_vram == size, 4.64 GB) | `/api/ps` per request |
| VRAM used at steady state, 4K | **4639 MiB** (median); card total 8192 MiB, reserved 359 MiB, usable 7833 MiB | nvidia-smi 1 Hz |
| VRAM headroom at steady state, 4K | **3553 MiB** against 8192 (the G1 table's definition) and **3194 MiB** against 7833 usable; the box needs ≥ 768 MiB | ollama-g1-table.py, nvidia-smi |
| VRAM, 8K (`num_ctx` 8192, 1 cold + 10 warm, run 15:23) | **4909 MiB** steady; headroom **3283 MiB** against 8192 and 2924 against 7833; decode p50 66.1 tok/s, TTFT p50/p95 1.74/1.75 s; gpu_share 1 | ollama-g1-table.py |
| GPU power, max | run 2: **131.8 W** (p95 130.2 W, the cap); run 1: 132.8 W | nvidia-smi |
| GPU temperature, max | **61 °C** (both runs); utilisation p50 98 % | nvidia-smi |
| kernel journal, run 1 window | **no** Xid, NVRM, OOM or reset lines (1 kernel line in total, unrelated) | `journalctl -k` |
| kernel journal, run 2 window | **memcg OOM kill of `llama-server`** at 15:22:15: `oom-kill:constraint=CONSTRAINT_MEMCG … oom_memcg=/system.slice/ollama.service … Killed process 1016817 (llama-server) … anon-rss:8321692kB … oom_score_adj:1000`. **No** Xid, NVRM, driver reset or GPU fault lines | `journalctl -k` |
| GPU OOM or driver reset | **none** in either window | kernel + ollama journals |
| host MemAvailable, min | run 2: **21.2 GiB**; run 1: 27.0 GiB. The host never ran short; the OOM was the service's cgroup | `/proc/meminfo` 1 Hz |
| Ollama after the kill | systemd `Failed with result 'oom-kill'`, restarted within 1 s (`NRestarts=1`), active since; 8K run after it was clean | `journalctl -u ollama` |

### The cause of the OOM kill (run 2)
llama-server saves every finished prompt into a host-RAM prompt cache: `idle slots will be saved to prompt cache upon starting a new task`. That cache's own limit is `8192.000 MiB` (journal: `cache state: N prompts, X MiB (limits: 8192.000 MiB, 4096 tokens …)`), which equals `ollama.service`'s whole `MemoryMax=8G`.

With distinct prompts it grew by about 81 MiB per request:

| time | prompts | prompt cache |
|---|---|---|
| 15:15:47 | 14 | 1128 MiB |
| 15:18:05 | 44 | 3546 MiB |
| 15:20:24 | 74 | 5965 MiB |
| 15:21:33 | 89 | 7174 MiB |
| 15:22:15 | 97 | 7818 MiB, then killed |

At anon-rss 8.3 GB the cgroup hit `MemoryMax` and the kernel killed the runner (it has `OOMScoreAdjust=1000`). Run 1 never reached it only because it reused 20 prompts.

Any steady single-user load with fresh prompts, a pi session or the gateway, would hit this after roughly 95 distinct 4K prompts while the model stays loaded. Longer contexts mean bigger entries and fewer prompts before the kill. It is a configuration defect: the cache limit is not below the service cap. Fixing it is a config change, which this task excludes. **For the owner:** a prompt-cache limit well below `MemoryMax` for the runner, or a larger `MemoryMax`, then re-run this stress.

## #492 G1 boxes (as written; none relaxed)

| G1 box (#492) | what this run shows | status |
|---|---|---|
| Identical Qwen2.5-Coder 7B Q4 workload **≥ 5× MSI's ~4.8 decode tok/s (≥ 24 tok/s)** on the RTX GPU | Decode p50 **70.0 tok/s** at 4K (p5 69.8, sustained over 455 s; 69.8 over 1813 s in run 1) and 66.1 tok/s at 8K; 100 % on the GPU. No msi row was re-measured today; the bar is the box's 24 tok/s | **met** (decode only; not as part of a completed 30-min run) |
| **≥ 0.75 GiB VRAM headroom at steady state** under a declared desktop-load scenario with 4K context | 4K steady 4639 MiB: headroom 3553 MiB of 8192, 3194 MiB of 7833 usable, both ≫ 768 MiB. Scenario: desktop **idle** (headless host) | **met for the idle scenario**; the desktop-in-use scenario is **not measured** (no desktop on asus) |
| Report the **8K** result even if it fails | 8K steady 4909 MiB: headroom 3283 / 2924 MiB, decode 66.1 tok/s | **reported** (it passes the 768 MiB bar) |
| **No GPU OOM/reset during 30 min** | No GPU OOM, Xid or driver reset in either window. But the valid 30-minute run did **not complete**: the runner was OOM-killed by its memory cgroup at 7 min 38 s (host RAM, not GPU). The 30-min window that did complete (run 1) had no GPU fault but reused 20 prompts, so it isn't the valid load | **not met**: no 30-minute run of the valid load completed |
| (G1 body) 30-min stress: **no crash / driver reset / host OOM**; model identity and quantisation captured | Crash: **yes**, `llama-server` OOM-killed (memcg) and restarted by systemd. Driver reset: none. Host OOM: none at host level (MemAvailable ≥ 21.2 GiB); the kill was the service cgroup's. Model qwen2.5-coder:7b-instruct Q4_K_M, digest dae161e2…, captured per request | **not met** (a crash) |
| ASUS Ollama reachable from Acer and not broadly from LAN | not measured here; covered by #496/#530/#536 and fleet-contract-test | not measured in this run |
| systemd recovery / `nixos-rebuild --rollback` | Partial evidence: systemd restarted Ollama 1 s after the OOM kill and it served the 8K run; the model cache was intact (no re-pull). Rollback was not exercised | **not measured** (rollback); recovery after a crash observed |
| Build, live evidence, resource profile and independent review linked | this file is live evidence; linking and review are the coordinator's | not measured here |

## Commands
```
cd ~/.cache/wt/g1-stress            # fresh worktree at origin/main a93c2385
flock -o /run/work-locks/heavy-work.lock ~/.cache/g1-run/bin/g1-stress.sh
  # run 2: scripts/ollama-g1-bench.sh 192.168.10.113 qwen2.5-coder:7b-instruct-q4_K_M 4096 1 400 $R/run/g1-stress.jsonl
  #        with nvidia-smi --query-gpu=timestamp,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,... -lms 1000
  #        and MemAvailable from /proc/meminfo every second
  # 8K:    scripts/ollama-g1-bench.sh 192.168.10.113 qwen2.5-coder:7b-instruct-q4_K_M 8192 1 10 $R/run8k/g1-8k.jsonl (re-run 15:23 after the restart)
python3 scripts/ollama-g1-table.py $R/run      # and $R/run8k
journalctl -k --since <start>; journalctl -u ollama --since <start>
```

## Raw data (on asus)
- `~/.local/state/fleet-lead/g1-stress/`: run 2, the valid load. Contents: `run/g1-stress.jsonl` (98 requests), `run/vram-asus.csv`, `run8k/` (the 8K reading), `memavail.log`, `kernel.log` (with the OOM kill), `ollama.log` (with the prompt-cache growth), `stress.log` and the window markers.
- `~/.local/state/fleet-lead/g1-stress-r1-cachedrepeats/`: run 1 (484 requests over 30 min 15 s, repeated prompts), with the same set of files.

---

# Run 3: after the prompt-cache fix (#551, asus at main 83ade5b7), 18 Nov 16:10:51–16:43:18

**Setup:** as for run 2, a single bench invocation of 1 cold + 400 warm requests at 4096, every prompt distinct. Additions:
- the deployed `LLAMA_ARG_CACHE_RAM=1024`;
- a 1 Hz sampler of `ollama.service`'s cgroup (`memory.current`, `anon`, `memory.events oom_kill`, `NRestarts`).

**Post-deploy checks first:**
- the unit environment has `LLAMA_ARG_CACHE_RAM=1024`;
- after one request, the runner logged `2026-11-18T16:10:34+01:00 asus-b460m ollama[1206589]: srv        update:  - cache state: 0 prompts, 0.000 MiB (limits: 1024.000 MiB, 4096 tokens, 1073741824 est)`.

| measurement | run 3 |
|---|---|
| requests completed | **402** (1 cold, 1 warm-up, 400 warm) over **1871 s (31 min 11 s)**, back to back, no error |
| decode tok/s, warm | **p50 70.0**, p5 69.9, p95 70.3 |
| TTFT, warm (2521 prompt tokens) | **p50 0.952 s, p95 0.971 s**, max 0.987 s; client-side with queue p95 1.04 s |
| GPU share | 1.0 on every request |
| VRAM, 4K steady | 4639 MiB; headroom **3553 MiB** of 8192, **3194 MiB** of the 7833 usable |
| VRAM, 8K (1 cold + 10 warm, after the 30 min) | 4909 MiB; headroom 3283 / 2924 MiB; decode p50 65.9 tok/s, TTFT p50/p95 1.75/1.75 s |
| GPU power, max | 132.8 W (130 W cap); utilisation p50 98 % |
| GPU temperature, max | 61 °C |
| prompt cache (runner journal, 414 `cache state` lines) | 0 → **plateau of 12 prompts, about 968 MiB** from 16:14:51 to the end; **never above 1024 MiB**. At the 8K run, 6–7 larger prompts, ≤ 1023.97 MiB |
| `ollama.service` memory (cgroup, 1 Hz) | max **1.35 GiB** current, **1.28 GiB** anonymous (run 2: 8.3 GB anonymous at the kill); `MemoryPeak` 1.44 GB including the 8K run; MemoryMax 8G |
| `NRestarts`, `oom_kill` | **0 → 0** and **0 → 0** for the whole window |
| kernel journal, window | **no** Xid, NVRM, OOM or reset lines |
| host MemAvailable, min | 27.8 GiB |

## #492 G1 boxes, updated with run 3 (none relaxed)

| G1 box (#492) | evidence | status |
|---|---|---|
| ≥ 24 decode tok/s (5× MSI) | 70.0 tok/s p50 over a full 31-minute run (p5 69.9), 100 % on the GPU; 65.9 at 8K | **met** |
| ≥ 0.75 GiB VRAM headroom at steady state, 4K, declared desktop-load scenario | 3553 MiB of 8192 / 3194 MiB of 7833 usable, steady over 31 min; scenario desktop **idle** (no desktop on asus) | **met (idle)**; desktop-in-use **not measured** |
| report 8K even if it fails | 4909 MiB, headroom 3283 / 2924 MiB | **reported** (passes) |
| **No GPU OOM/reset during 30 min** | run 3: no GPU OOM, Xid or reset over 31 min 11 s of distinct-prompt one-request load | **met** |
| (G1 body) 30-min stress: **no crash / driver reset / host OOM**; model identity and quant captured | run 3: no crash (`NRestarts` 0, `oom_kill` 0), no driver reset, no host OOM (MemAvailable ≥ 27.8 GiB); model qwen2.5-coder:7b-instruct Q4_K_M, digest dae161e2…. Run 2's crash was the prompt-cache cap, fixed by #551 and verified here | **met** |
| reachable from Acer only; rollback; links and review | not part of this run | not measured here |

**Verdict:** with the prompt cache capped at 1024 MiB, the 30-minute distinct-prompt one-request stress on asus completed **without a crash, OOM or driver reset**. The #492 30-minute no-crash box is **met**.

Raw data: `~/.local/state/fleet-lead/g1-stress-r3/` (`run/g1-stress.jsonl` 402 requests, `run/vram-asus.csv`, `run8k/`, `cgroup.log`, `memavail.log`, `kernel.log`, `ollama.log`, `stress.log`). Run 2's data moved to `g1-stress-r2-oomkill/`.
