# ASUS: quiet GPU capacity for Pi agents

Owner goal (19 November 2026): support as many Pi agents as possible while respecting power,
performance and an unobtrusive fan. Track measurements in #493, actual Pi task quality in #494,
and the fleet in #491/#600. This source slice is #604. This is an experiment contract, not a capacity claim.

## Objective and present constraints

Maximize **test-verified completed coding tasks per minute** subject to acceptable desk noise,
latency, task correctness, power, temperature and memory. Report the number of active agent sessions
separately from simultaneous inference requests: agents also spend time running tools or waiting.
A longer queue is not additional useful capacity.

The RTX 3070 has 8192 MiB physical VRAM; the live driver is 595.104.02 and Ollama reports 0.40.3.
The active board limit is 130 W (hardware range 100–270 W). Retain it for the first baseline.
The installed service already enables Flash Attention and q8_0 KV cache, one resident model,
one parallel request, 32768 context, 1024 MiB host prompt-cache budget and a five-minute keep-alive.
Do not count enabling these existing settings as a new optimization. Source assertions currently
reject parallelism other than one; a concurrency experiment needs an explicit reviewed candidate.

Owner confirmation: “This is fine I will tune it if needed, the power level we have set is the
limit for now (130W)”. Treat 130 W as the fixed envelope; retain automatic fan control and let
the owner tune acoustics if needed. Fan demand is a useful proxy, not a sound measurement. Record perceived noise at the normal seat, distance, room temperature,
background noise and chassis/CPU fans. If a calibrated meter is available, record LAeq/dBA and
measurement setup separately. Do not infer dBA from a fan percentage or slow the fan manually
while leaving heat output unchanged. The previous 130 W stress result around 70% fan is not proof
of acceptable quietness.

The persistent ASUS shutdown calendar covers every evening at the fleet night start,
including weekends, so a manual Saturday wake still ends that night. Automatic wake
keeps its weekday policy; an explicit experiment window still controls manual wakes.
The timer has no persistent catch-up. Verify the installed timer after an approved
activation: a source change does not update a running host's calendar.

## Research that changes the next experiment

- [Ollama's concurrency and cache documentation](https://docs.ollama.com/faq) says parallel
  contexts increase memory demand; Flash Attention permits quantized KV caches. On this host
  those cache settings already exist. Test context and parallel slots together, checking actual
  loaded context and GPU residency. A smaller context is admissible only for tasks that fit:
  Pi conversations previously reached about 18.5K context tokens, so 4K/8K is not a safe universal
  replacement for 32K. Cache quantization also requires task-quality verification.
- [PagedAttention / vLLM, SOSP 2023](https://arxiv.org/abs/2309.06180) demonstrates the relevance
  of KV memory management and batching to serving throughput. It motivates a comparison; its
  published speedups do not predict RTX 3070 results. First measure the existing native engine.
  The optional Paddock comparison remains #508, with identical supported weights, tokenizer,
  quantization, context and cache policy. Mark unmatched models non-comparable.
- [NVIDIA's nvidia-smi reference](https://docs.nvidia.com/deploy/nvidia-smi/) distinguishes
  intended fan speed, thermal slowdown and software power capping. Show these separately:
  intentional power limiting can be normal; thermal slowdown rejects a candidate. GPU watts
  exclude CPU/chassis/PSU consumption, and sampled watts do not establish whole-host energy.

The HPC questions are deliberately narrow: does batching amortize weight reads enough to improve
useful throughput at 130 W, and does KV memory permit two real task contexts without offload?
Separate prefill, decode and tool-idle time; GPU utilization alone cannot identify the bottleneck.
[FlashAttention (NeurIPS 2022)](https://arxiv.org/abs/2205.14135) frames attention as an IO
problem and reduces memory traffic. It supports inspecting context/cache use, not assuming a
speedup from a switch already enabled here. Compare shared-prefix and independent-session
workloads separately so cache reuse cannot inflate the general capacity result. Record cache hits
and prompt-evaluation tokens where the runtime exposes them; report unavailable values honestly.
Kernel profiling, speculative decoding or another engine is a later experiment only if measured
prefill/decode/queue data identifies a need; do not add profiling overhead to acceptance timings.

Sources consulted 19 November 2026. Current upstream documentation describes mechanisms;
verify each option against the installed 0.40.3 runtime before changing it.

## Measurements and ownership

Use the existing GPU exporter and black-pi Prometheus/Grafana/Loki. The LLM gateway dashboard
adds fan demand, board draw versus limit, and separate hardware-thermal/software-power reason panels. These read
already exported metrics; they add no daemon, port or scrape load. No-data stays unknown.
The [observation record](records/asus-quiet-gpu-baseline-2026-11-19.md) captures the initial live window.

| Measurement | Existing source / remaining work |
|---|---|
| Fan, temperature, board draw/requested software limit, VRAM, utilization, HW thermal/SW power flags | `nvidia-gpu` job; new dashboard panels expose quietness inputs (#493) |
| Queue wait, in-flight/queued/rejected, first content token, completion, cancellation | Existing gateway capacity work `sammasak/llm-gateway#101`; distinguish first byte from content token |
| Prompt/decode tokens, loaded context, GPU residency, cold/warm timings | Existing `llm-bench` and G1 harness, #493 |
| Correct edits and tests, actual tool execution, retries, task completion | Throwaway fixtures and Pi hooks, #494; process exit and emitted tool calls alone are insufficient |
| Host RAM/CPU, failed units, OOM, gate duration and wait | Existing node/shipping telemetry; measurement gaps #596 |
| Driver Xid/errors | Existing journal/Loki panel; inspect the exact trial window |
| Whole-host energy and acoustic sound level | Unavailable unless separately measured; never substitute GPU watts or fan demand |

For a controlled run capture fan/temperature/VRAM/board watts at 1 Hz on ASUS, with monotonic
sample intervals and a UTC alignment marker. Prometheus's normal 10 s scrape is adequate for
long trends but can miss peaks and short requests. Include direct `enforced.power.limit` and both
`clocks_throttle_reasons.hw_thermal_slowdown` and `clocks_throttle_reasons.sw_thermal_slowdown`
in the 1 Hz trial capture. The exporter source includes requested and enforced limits and
both thermal reasons. Their history begins only after the corresponding exporter is
activated and successfully scraped; earlier requested-limit/HW-only history cannot
establish software thermal behavior or the effective cap. Missing series remain unknown.
Integrate board watts over the **whole trial**
using actual elapsed intervals; report sampling gaps and GPU joules per verified successful task,
including failed requests, retries and idle gaps within that interval. Report gross board energy;
any idle-subtracted estimate must be separate. Do not divide unrelated historical power and token
rates or attribute shared GPU energy to an individual agent without an allocation method.
Keep per-trial identifiers in private artifacts; no prompts, code, tool arguments, replies or
session identifiers in Prometheus labels.

## Staged experiment

1. **Offline / first slice:** expose existing quietness inputs on the provisioned dashboard,
   validate all PromQL against the deployed metric catalog, record live coverage and missing
   measurements, and review this protocol. Do not modify model routing or runtime settings.
2. **Controlled baseline:** after a named, scheduled ASUS experiment is approved and sessions
   are parked, use the existing heavy-work lock, daylight power window and harness in
   [local-inference-bench.md](local-inference-bench.md). Pin source SHA, runtime, driver,
   model manifest/weights, tokenizer/quant, loaded context, sampling, prompt-cache policy,
   power limit and ambient conditions. Capture inference-only first; gate contention is a
   separate workload. Record cold separately, at least 5 cold / 20 warm requests and the #494
   actual-tool task fixtures. No locally runnable model is promoted without passing quality.
3. **Concurrency candidate:** retain 130 W; compare request slots 1 then 2 using one resident,
   quality-qualified model and contexts that fit the actual task. Ramp offered agents 1/2/4,
   higher only after the prior row passes. Keep actual loaded context and request concurrency
   distinct. Require at least 768 MiB free VRAM under peak observed load (existing G1 margin),
   full GPU residency, no OOM/Xid/thermal slowdown and no silent truncation. Cancel the ramp
   at the first violation, runaway queue, timeout or owner noise objection. Revert the candidate
   to baseline settings. Never bypass the source assertion or quietly spill to CPU.
4. **Sustained quietness observation:** keep the same 130 W limit and automatic fan controls.
   Hold each passing candidate under load for at least 20 minutes or until temperature and fan
   settle, whichever is longer. Record fan demand, ambient temperature and owner feedback.
   Verify the board limit after loads/restarts. Stop load for thermal slowdown or an owner noise
   objection. Do not change the power cap, fan curve or clocks in this experiment.
5. **Selection:** choose the highest task throughput meeting the owner-accepted fan behaviour and quality,
   plus the existing proposed capacity limits (p95 first content token ≤5 s, per-agent decode
   ≥10 tokens/s, queue wait p95 ≤3 s). These latency limits still need owner ratification;
   they are not a claim of current acceptance. Run #494's ≥10 distinct tasks / ≥20 actual-tool
   opportunities per model and require its quality gate. Publish sample counts, distributions,
   failures and energy denominator. Report no-go if none qualify. Review and operator approval
   precede any persistent runtime/routing rollout.

The benchmark implementation stays in nixos-config's existing `llm-bench`; gateway admission,
queue limits and model affinity stay in llm-gateway; reusable Pi telemetry stays in devenv-platform
(#155 there). Avoid an additional scheduler, benchmark framework, exporter or GPU runtime just
to increase apparent agent count. Model quality is currently an unresolved prerequisite (#494).
