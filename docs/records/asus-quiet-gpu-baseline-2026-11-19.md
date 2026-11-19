# ASUS GPU quiet-capacity observation — 19 November 2026

Read-only measurements from ASUS and black-pi Prometheus. This mixed-workload window is not
an inference-capacity benchmark, a sound test or evidence for increasing concurrency.

Direct `nvidia-smi` observation: RTX 3070, 8192 MiB, 14.80 W board draw, enforced 130 W limit,
39°C, intended fan 0%, utilization 0%; supported board limit 100–270 W.
Ollama was active with no resident models at the subsequent `/api/ps` observation.
Driver 595.104.02; `/api/version` 0.40.3. Live service environment confirmed context 32768,
parallel requests 1, resident models 1, Flash Attention 1, KV cache q8_0, prompt-cache budget
1024 MiB and keep-alive 5m. No inference, model download, service restart or power change ran.

Prometheus window: two hours ending at the UTC evaluation time recorded below.
Every selector below includes `node="asus-b460m"`; `up` additionally uses `job="nvidia-gpu"`.

| PromQL | Value |
|---|---:|
| `avg_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])` | 1.0 |
| `count_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])` | 720 |
| `avg_over_time(nvidia_smi_last_collect_success{node="asus-b460m"}[2h])` | 1.0 |
| `quantile_over_time(0.95,nvidia_smi_fan_speed_ratio{node="asus-b460m"}[2h])` | 0.0 |
| `max_over_time(nvidia_smi_fan_speed_ratio{node="asus-b460m"}[2h])` | 0.62 |
| `max_over_time(nvidia_smi_temperature_gpu{node="asus-b460m"}[2h])` | 57°C |
| `max_over_time(nvidia_smi_power_draw_watts{node="asus-b460m"}[2h])` | 129.88 W |
| `max_over_time(nvidia_smi_utilization_gpu_ratio{node="asus-b460m"}[2h])` | 0.96 |
| `nvidia_smi_power_limit_watts{node="asus-b460m"}` | 130 W |
| `max_over_time(nvidia_smi_clocks_event_reasons_hw_thermal_slowdown{node="asus-b460m"}[2h])` | 0 |

All queries succeeded without warnings. The 720 observed up samples cover a continuously-on
2h interval at 10 s cadence. This supplies a fresh #493 scrape-coverage receipt, not an acoustic
acceptance receipt. The fan briefly reached 62% while p95 was 0%; reporting only p95 would hide
that event. Peak temperature, power, fan and utilization need not occur simultaneously.
These sampled maxima can miss excursions between scrapes. No task-success, loaded-workload,
whole-host energy or dBA measurements were made; no agent capacity is inferred.

Evaluation time: `2026-11-19T18:49:21.963048+00:00`. Raw query responses retained locally at
`~/.cache/asus-quiet-baseline.json` (not needed to interpret the values above).
