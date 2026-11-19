# ASUS trial — 20 November, after 09:00 Stockholm time

Owner constraints: ASUS stays off before 09:00 Europe/Stockholm; 130 W is the board-power
limit; keep one heavy job at a time. Builds and static preparation do not authorize waking
ASUS overnight. Inference and host activation wait until the morning. The live 08:30 wake
timer was stopped. Keep it stopped tonight; do not blindly restore its old 08:30 schedule.
A permanent wake-time change requires a deliberate follow-up because the current source
shares one night boundary across the fleet. Other hosts' power schedules are unchanged.

## Prepared artifacts and acceptance status

- #603: restart counters, Pi model/tool attribution and fleet baseline; full QA/source review pass.
- #605: CPU-accounting diagnostic, stacked on #603; full QA/source review pass.
- #606: narrow Loki INFO lookup filter and real Alloy/negative harness checks; full QA/review pass.
- #607 / #604: fan, requested board-power limit and hardware/software reason distinctions;
  full QA/review pass. No physical capacity improvement is inferred.
- Backup completion slice #564: owning fixture/catalog checks and source review pass;
  full QA **failed** at `2cfe9fbe` in `nixos-flake-check` (69 s). The complete gate lasted
  214 s and failed before shutdown. Retrieve the actual log after 09:00; do not activate it
  or count source checks as full acceptance. An unrelated local monolithic no-build flake
  evaluation exited 137; that does not establish the ASUS failure's cause.
- This candidate: an explicit `homelab.ollama.parallelRequests = 2` option, with default 1.
  Keep one resident model, pinned weights, 32K context, q8_0/Flash Attention, the existing
  host RAM limit and 130 W. Static policy checks are not VRAM-fit or task-quality evidence.
- The existing benchmark package was built and copied to always-on Acer without waking
  ASUS: `/nix/store/8a8drm4847xh7k26a0bddy1f5mr4qimb-llm-bench`.

## Clock and read-only preflight

Run `python3 scripts/asus-trial-preflight.py` from this source. It refuses even an SSH
connection before **2026-11-20 08:00 UTC / 09:00 CET**. It never wakes, builds, activates,
restarts or sends an inference request. At/after the boundary it collects driver/memory,
requested and enforced power, fan/thermal flags, failed units, Ollama version and resident
model state. Read-only collection success is not trial acceptance. Stop if the enforced
limit is above 130 W, there are unexplained failed units or thermal/driver errors, or the
owner finds the noise disruptive. Do not wake ASUS early to fix readiness.

If the owner is ready at/after 09:00, use the existing waker only then; this document does
not schedule an automatic wake. Inspect backup QA logs before retrying that gate. Confirm
no build or other inference job owns ASUS's `/run/work-locks/heavy-work.lock`.

## Build-only candidate from a recorded revision

From a clean checkout containing this change, record `git rev-parse HEAD` and use that full
revision. The expression reads that committed revision, not unstaged edits:

```bash
nix build --impure --file scripts/asus-capacity-candidate.nix \
  --argstr revision "$(git rev-parse HEAD)" --arg parallelRequests 2 \
  --out-link result-asus-two-slots
```

Use `--dry-run --no-link` first when preparing on another host. If CUDA or the NVIDIA
package would compile there, defer that build to the approved ASUS window rather than
loading a service host. The expression requires the 130 W cap and 32K context and permits
only one or two slots. Building does not activate anything. Do not use `result.../bin/switch-to-configuration`
to bypass deployment gates. Review the exact closure/diff, complete required QA and preserve
the existing generation before any separately approved candidate activation.

## Morning measurement order

1. **Baseline first:** keep the current one-slot configuration. Record source revision,
   Ollama/driver, model digest, actual loaded context, requested/enforced power and host load.
   Run one fixed model/workload at a time and hold the ASUS heavy-work lock for the complete
   trial. Prefer the existing G1 protocol in [local-inference-bench.md](local-inference-bench.md).
2. **Observe continuously:** capture idle, load and cooldown GPU data at 1 Hz, including fan,
   temperature, memory, board watts/limit and both thermal flags. For energy integration use
   actual elapsed sample intervals; wall-clock-only CSV is a trend, not precise joules/task.
   Keep raw per-run artifacts private; never publish prompts, source or tool payloads.
3. **Bound offered agents:** start with max 2 offered agents and 20 observations per level,
   using the existing capacity command below. This measures queueing behind the one-slot
   runtime. `--ctx 4096` describes the synthetic fixture; the actual `/v1` server context is
   still **32768**, recorded by the harness. Do not rename queued clients parallel inference.
4. **Quality:** use #494's throwaway coding/tool fixtures and observe actual tool execution
   and tests. Qwen's raw speed and past Gemma runs do not qualify a local Pi model. Keep
   cloud/default routing unchanged. If no model passes, record a quality no-go.
5. **Two-slot candidate only after baseline and source/activation gates:** repeat the identical
   workload, model/digest, loaded context, cache policy and power at two request slots. Require
   full GPU residency, at least the existing 768 MiB headroom margin, no truncation/OOM/Xid/
   thermal slowdown and acceptable latency/noise. Stop and restore the recorded baseline
   configuration at the first violation. Do not reduce real task context to fabricate fit.
6. **Sustained acceptance:** heat-soak at least 20 minutes or until fan/temperature settle,
   whichever is longer, after the short candidate passes. Compare successful tested tasks
   per minute, per-agent p95 latency, queueing, errors/retries and whole-trial GPU energy per
   successful task. Report sample counts and failed trials. Promote nothing on tok/s alone.

After the clock/preflight/lock and owner readiness checks, run the prebuilt tool **from Acer**:

```bash
/nix/store/8a8drm4847xh7k26a0bddy1f5mr4qimb-llm-bench/bin/llm-bench capacity \
  --base http://192.168.10.113:11434/v1 --host asus-b460m \
  --model qwen2.5-coder:7b-instruct-q4_K_M --ctx 4096 --route direct \
  --max-agents 2 --per-level 20 --out ~/.local/state/asus-trial-2026-11-20
```

This is a bounded synthetic baseline, not verified coding capacity. Repeat with another
quality-qualified model only as a separate recorded trial. No model downloads or new default
routes are part of this preparation. See [quiet-capacity protocol](asus-quiet-agent-capacity.md)
for the research, matched comparisons, energy limitations and existing issue ownership.
