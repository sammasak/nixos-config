# Real pi sessions at 32K on asus-b460m, 17 Nov 2026, 16:37–17:22 CET

The setup was the main da30977 deploy (#515): RTX 3070 at a 130 W cap, persistence on, Ollama 0.40.3 CUDA with `OLLAMA_CONTEXT_LENGTH=32768`, `NUM_PARALLEL=1` and KV q8_0. The client was `pi` 1.2.0 with a scratch `PI_CODING_AGENT_DIR` (provider `asus-ollama`, `http://192.168.10.113:11434/v1`, `contextWindow` 32768, `maxTokens` 2048) and `--thinking off`. Each session ran as `pi -p --mode json`, capped at 14 min.

The repo was a scratch clone of nixos-config at da30977 (`~/.cache/pi32k/base`). Each session got a fresh worktree, so nothing was committed and nothing touched the real checkout.

Every session held `/run/work-locks/heavy-work.lock` on its own, the longest for 2 min 41 s. No config or service change was made.

**Judging:** each result was judged by me, after the session, by running the test or comparing outputs, not by what the agent said. Per-call numbers come from Ollama's journal (llama-server slot lines): context tokens sent, prefix reused from the KV cache, tokens evaluated, prompt-eval time (the server-side TTFT), decode tok/s, and the `truncated` flag.

## Summary
| task | model | result (judged) | turns | wall | context start→max | TTFT per call p50 / max | decode tok/s | truncated |
|---|---|---|---|---|---|---|---|---|
| 1 seeded bug, 2 files | e4b | **fail**: invented a config file, test still fails, claimed fixed | 11 | 58 s | 2.7K→17.6K | 0.10 / 3.05 s | 69–85 | 0 |
| 1 (repeat) | e4b | **test passes, fix wrong**: masked the missing key with `t.get(…, 0.0)`, which silently disables that threshold | 9 | 94 s | 2.7K→20.8K | 0.24 / 2.95 s | 66–84 | 0 |
| 1 | **e2b** | **fail**: rewrote an unrelated fixture, test still fails, claimed it "addresses" the failure | 8 | 48 s | 2.7K→12.7K | 0.08 / 0.81 s | 119–133 | 0 |
| 1 (repeat) | **e2b** | **fail**: read a non-existent `thresholds.json` path and stopped | 4 | 25 s | 2.7K→14.4K | 0.16 / 1.78 s | 117–135 | 0 |
| 2 add a check + test | e4b | **fail**: all four `edit` calls rejected ("could not find the exact text"), nothing changed, stopped without claiming success | 8 | 73 s | 2.8K→20.5K | 0.07 / 2.88 s | 67–86 | 0 |
| 3 explain, then refactor | e4b | **explanation correct; refactor broken**: deleted `fmt()`, script crashes. Its own `diff` showed the output changed, but it claimed "identical output" | 8 | 69 s | 2.8K→9.9K | 0.21 / 0.91 s | 77–86 | 0 |
| 4 read 17 files, write an inventory (past 32K), pi defaults | e4b | **fail**: compacted at 27.5K, then answered with a partial list, never wrote the file | 14 | 74 s | 2.7K→26.0K | 0.66 / 8.37 s | 63–88 | 0 |
| 4 with `compaction.reserveTokens` 4096 | e4b | **fail**: 3 compactions (28.7K, 31.2K, 29.4K), each followed by a full re-read, no file | 21 | 161 s | 2.7K→28.8K | 0.66 / 8.85 s | 62–88 | 0 |
| 4 with `compaction.enabled` false | e4b | **partial**: read all 17 files, plus one invented path, and put the inventory in its chat answer, but never called `write` | 21 | 108 s | 2.7K→32.4K | 0.65 / 10.81 s | 59–86 | 0 (see below) |

**Overall:** 0 of 9 sessions produced a correct, test-verified result. The only test that passed did so because the fix disabled the failing check.

**Not counted:** two earlier task 2/3 sessions hung for the full 14 min before their first request, because `pi -p` was waiting on stdin (see "What breaks"). They are excluded, and both were re-run.

Per-call tables for each session are in `runs/<name>/calls.md`. Examples from task 4 with compaction off:

```
#  context  reused  evaluated  TTFT s  tok/s  call s
1    2698       0      2698     0.74    86     2.9
14  26069   23321      2748     1.13    63     3.3
17  30819   28913      1906     0.86    60     3.6
18  31902       0     31902    10.81    60    15.3   <- prefix changed: Ollama dropped old messages
19  32388   32142       246     0.14    59     2.2
20  30327       0     30327    10.15    60    13.2   <- again
```

## What works
- **Speed while the context only grows.** Ollama's KV cache reuses the shared prefix on nearly every call, typically 90–99 % of the context. Typical calls get their first token in **0.05–0.3 s**; a 100–300-line file read costs **0.5–1.3 s**. A whole turn, a short reply plus a tool call, takes **1.5–4 s**. A 10-turn session is about a minute of wall time.
- **Decode slows as the context fills:** e4b from 85–88 tok/s at 3K to about 60 tok/s at 30K; e2b from 133 to 117 tok/s at 14K.
- **Tool calling through `/v1` works for gemma4 with thinking off.** It produces structured calls for `read`, `bash`, `edit` and `write`. (qwen2.5-coder doesn't; see the earlier ctx result.)
- **Reading and explaining.** Task 3's explanation of `ollama-g1-table.py`, including how the G1 verdict is decided, was accurate and concise. Task 4 with compaction off summarised 17 modules correctly in its answer.
- **Heat and noise at 130 W under real use:** 712 one-second samples across the sessions. Power held at the cap (p50 and p95 130 W, max 131 W), temperature p50 57 °C and at most 60 °C, fan p50 62 % and at most 66 %, GPU utilisation 88–96 % while generating.

## What breaks
1. **Correctness, not speed, is the limit.**
   - e4b and e2b both look in the wrong place: invented paths such as `fixtures/threshold_config.json`, `mock-thresholds.json` and `llm-gateway.0.nix`.
   - They make exact-match `edit` calls that don't match the file.
   - Most seriously, they **declare success when their own test or diff says otherwise** (3 of 9 sessions).
   - Unattended edits from these models can't be trusted. Every change needs a human or a test to check it.
2. **pi's compaction doesn't save a session at a 32K window.**
   - With defaults it fired at 27.5K tokens, not at the documented `contextWindow − reserveTokens` = 16384. By the numbers, the effective reserve looks capped near 8K (no compaction at 23.6K, compaction by 25.1K). That's inferred, not documented.
   - It summarised only the old part. `keepRecentTokens` defaults to 20000, so after compaction the next request was still about 26K tokens, and with a new prefix: a full re-read at **8.4 s TTFT** and a 31 s call.
   - With reserve 4096 it compacted three times in one session, each costing a 7.6–8.9 s re-read. In every compacted session the agent then lost track of the task and stopped without doing it.
3. **Ollama truncates silently.** With compaction off, the context reached 32388 tokens. Ollama then dropped old messages in its chat layer, which is visible only as a request with 0 reused tokens and a 10–11 s TTFT. llama-server's `truncated` flag stays 0, and Ollama logs nothing at INFO. From the agent's side, the only symptom is a slow turn.
4. **`pi -p` hangs if stdin is open.** When stdin is a pipe that never closes, `pi -p` waits on it before sending anything. Two 14-minute sessions were lost this way. With `</dev/null` it answers in about 4 s. Always script it as `pi -p "…" </dev/null`.
5. **Ollama's memory cap is reached in normal use.**
   - After these sessions the `ollama.service` cgroup sits at its `MemoryMax`: MemoryCurrent 8.587 GB against 8.590 GB. That is 4.3 GB anonymous, mostly llama-server's in-RAM prompt cache, which logs `cache state: 13 prompts, 3727 MiB (limits: 8192 MiB …)`, plus 3.8 GB of reclaimable file cache. `memory.events` shows `max` 1477 (cache reclaimed), with no `oom` and negligible pressure.
   - The risk: that prompt cache's own limit, 8192 MiB, is the service's whole `MemoryMax`. As it grows over a long day, anonymous memory alone can hit the cap, and the runner is the OOM-kill target (`OOMScoreAdjust=1000`).
   - **For the owner:** a smaller cache limit for the runner, or more `MemoryMax`. Not changed here.

## Recommendation for daily use
- **Model and settings:** **gemma4:e4b-it-qat, `--thinking off`, `contextWindow` 32768**, defaults otherwise.
  - e2b is 1.5× faster (117–135 tok/s), but it failed the same task faster and with less effort.
  - qwen2.5-coder can't drive `pi`'s tools through `/v1`.
- **Use it for:** reading, explaining and summarising code. Use it for small, checkable edits where you run the test yourself. Keep sessions **under about 20K tokens**, roughly 6–10 file reads; there, every turn answers in about 0.1–1 s and the whole turn takes a few seconds.
- **Start a new session rather than let one compact or truncate.** Past about 25K, pi either compacts, giving a 7–9 s re-read and a lost thread, or Ollama drops history, giving a 10–11 s re-read and possible loops.
- **Don't use it unattended for multi-file fixes or refactors.** In these runs it never produced a correct result without help, and it reports success it didn't achieve.
- **Scripting:** always `</dev/null`, and judge by the exit code of the test you run, never by the agent's summary.

## Exact commands
```
mkdir -p ~/pi-asus && cat > ~/pi-asus/models.json <<'EOF'
{ "providers": { "asus-ollama": {
    "baseUrl": "http://192.168.10.113:11434/v1", "api": "openai-completions", "apiKey": "ollama",
    "models": [
      { "id": "gemma4:e4b-it-qat", "contextWindow": 32768, "maxTokens": 2048, "reasoning": true },
      { "id": "gemma4:e2b-it-qat", "contextWindow": 32768, "maxTokens": 2048, "reasoning": true } ] } } }
EOF
# interactive, from asus itself or acer (asus's Ollama admits acer and loopback only)
cd ~/some-repo && PI_CODING_AGENT_DIR=~/pi-asus pi --model asus-ollama/gemma4:e4b-it-qat --thinking off
# scripted (note </dev/null)
PI_CODING_AGENT_DIR=~/pi-asus pi -p --mode json --model asus-ollama/gemma4:e4b-it-qat --thinking off "…task…" </dev/null > run.jsonl
# variants measured above: put in ~/pi-asus/settings.json
#   {"compaction":{"reserveTokens":4096}}   or   {"compaction":{"enabled":false}}
```

**How each session ran:** `~/.cache/g1-run/bin/pi_session.sh NAME BRANCH AGENT_DIR MODEL PROMPT_FILE JUDGE` under `flock -o /run/work-locks/heavy-work.lock`. Per-call tables come from `python3 -I ~/.cache/g1-run/bin/pi_calls.py ~/.cache/pi32k/runs/NAME`.

**The tasks** (prompts in `~/.cache/pi32k/prompts/`):
1. **Seeded bug:** capacity key `decode_tps_per_agent_min` renamed to `decode_tps_agent_min` in `pkgs/llm-bench/thresholds.json`. `scripts/test-llm-bench.py` then fails with a KeyError raised in `llm_bench.py`.
2. **Validation:** add validation to `thresholds()` and a test for it.
3. **Refactor:** explain `scripts/ollama-g1-table.py`, then refactor out `g1_verdict()` with byte-identical output.
4. **Inventory:** read all 17 `modules/homelab/*.nix` files (about 99 KB) and write `INVENTORY.md`.

**Judges** (`~/.cache/pi32k/judge-t*.sh`):
1. the test's real exit code;
2. that, plus `thresholds()` fed −1, 0, `true` and `"10"`;
3. the output diff against the original script;
4. `INVENTORY.md`'s presence and file coverage.

## Raw output
`~/.cache/pi32k/runs/<name>/` holds, for each session:
- `pi.jsonl` (pi's event stream) and `pi.stderr`;
- `ollama-journal.log` (the window) and `calls.jsonl` / `calls.md` (per call);
- `gpu.csv` (1 Hz, with power, temperature and fan);
- `judge.txt`, `agent.diff`, `agent.status` and `meta.json`.

pi's own session files are in `~/.cache/pi32k/sessions/<name>/`, and the two stdin-hung sessions are in `runs/hung/`.

## Could not measure
- **Interactive TTFT as seen in the TUI.** Measured here are server-side prompt-eval and per-call wall time; the TUI's rendering isn't included.
- **Larger task samples.** These are one or two runs per task. Results vary between runs (task 1 on e4b: a false fix once, a masked fix once), so the failure pattern is clear but the rates are not precise.
- **e2b on tasks 2–4,** and any model other than the pinned three.
- **Whether a smaller `keepRecentTokens`** (e.g. 8000) makes compaction actually free space at 32K. Not run, and worth one try.
- **Whether the runner gets OOM-killed** once the prompt cache grows past about 4.5 GB of anonymous memory. It didn't happen in these 45 minutes.
