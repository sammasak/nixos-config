# #492 / #493 close-out from asus-b460m, 18 Nov 2026, ~17:00

**Scope:**
- **State:** asus is running main e5ba55f4. `/run/current-system` = `j7qbimwk…`, identical to the toplevel I evaluated at e5ba55f4, so the rendered config below is the running one.
- **Limits:** read-only throughout: no switch, no rollback, no sudo, no config, threshold or service change.
- **What asus cannot reach:** I cannot SSH to other hosts, and asus cannot reach black-pi's Prometheus or Grafana (`192.168.10.137:9090` and `:3000` time out from asus). Those parts are exact commands and queries for you to run.

## #492 (PoC A): the boxes as written

| # | box (verbatim) | evidence | status |
|---|---|---|---|
| 1 | Identical Qwen2.5-Coder 7B Q4 workload **>=5x MSI's measured ~4.8 decode tok/s** (i.e. >=24 decode tok/s) on the RTX GPU | 70.0 tok/s p50 over the 31-min distinct-prompt run 3 (p5 69.9), 100 % on the GPU, at the 130 W cap; 65.9 at 8K (`g1-stress-run.md`, run 3). 75.4 tok/s at 270 W in the morning G1 run (`g1-result.md`). No msi row was re-measured; the bar is the box's own 24 | **met** |
| 2 | >=0.75 GiB of VRAM headroom at steady state under a declared desktop-load scenario with 4K context; report the 8K result even if it fails. No GPU OOM/reset during 30 min. | 4K steady 4639 MiB: headroom 3553 MiB of 8192 and 3194 of the 7833 usable. 8K: 4909 MiB, headroom 3283 / 2924, reported. Run 3: 31 min 11 s with no GPU OOM, Xid or reset, no runner crash (`NRestarts` 0, `oom_kill` 0), after #551 | **met for desktop idle** (the only scenario asus has: no graphical session). **Desktop-in-use: needs owner** (no desktop on asus; either accept idle as the declared scenario or name a load) |
| 3 | ASUS Ollama is reachable from Acer and **not** broadly from LAN; existing Pi/cloud/gateway unchanged | see "Reachability" below. The rendered and running firewall admits 11434 from 192.168.10.110 (acer) only, with no any-source port, no trusted interface but `lo`, and Ollama bound to 192.168.10.113 only. Live connects from other hosts cannot be run from asus | **met on config; live part needs coordinator** (the four commands below) |
| 4 | Native `systemd` recovery and `nixos-rebuild --rollback` procedure demonstrably restore previous state; no persistent model-cache deletion. | systemd recovery **observed**: run 2's memcg OOM kill at 15:22:15, then `Scheduled restart job … restart counter is at 1` and `Started` at 15:22:16; it served the 8K run with no re-pull. Rollback **documented, not demonstrated** (below). Model cache outside the Nix store (below) | systemd recovery **met (observed)**; rollback **needs owner** (a demonstration is a switch, the owner's decision); no model-cache deletion **met on config** |
| 5 | Build, live evidence, resource profile and independent review linked here. | builds and gates: #496, #506, #511/#512 (#515), #530, #533, #536, #543, #551, #552; live evidence: `g1-result.md`, `ctx-result.md`, `swap-32k.md` (#492 comment), `pi-32k-result.md`, `g1-stress-run.md` (#492 comment 6981739979); reviews by msi wQ:p1 and wZ on each PR | **needs coordinator** (linking on the issue) |

### Reachability (box 3)
**Rendered and running config** (eval at e5ba55f4 = running `j7qbimwk…`):
- `networking.firewall`: `enable = true`, `backend = "iptables"`, `allowedTCPPorts = [ ]`, `allowedTCPPortRanges = [ ]`, per-interface ports `{ }`, `trustedInterfaces = [ "lo" ]`, `rejectPackets = false` (so a blocked client times out; it gets no "refused").
- `systemctl is-active firewall`: `active`.
- **The only rules for Ollama and its exporter**, from `extraCommands`:
  ```
  iptables -w -A nixos-fw -s 192.168.10.110 -p tcp --dport 11434 -j nixos-fw-accept   # acer-swift (its only fleet address)
  iptables -w -A nixos-fw -s 192.168.10.137 -p tcp --dport 9835  -j nixos-fw-accept   # black-pi end0 (GPU exporter)
  iptables -w -A nixos-fw -s 192.168.10.136 -p tcp --dport 9835  -j nixos-fw-accept   # black-pi wlan0
  ```
- **Bound sockets** (`ss -ltn`): `192.168.10.113:11434` (Ollama), `192.168.10.113:9835` (exporter), `192.168.10.113:9100`, `*:5000` (Harmonia, firewalled to the fleet by #536).
- **Fleet addresses:** acer 192.168.10.110; lenovo .154; msi .235; black-pi .137 and .136; asus .113.
- **Live from asus:** `curl http://192.168.10.113:11434/api/version` gives 200 in 0.3 ms. That only shows the service is up: asus reaching its own address goes over trusted `lo`, so it proves nothing about the LAN filter.

**Live tests I cannot run from asus (please run, read-only):**

| from | command | expect |
|---|---|---|
| acer-swift | `curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://192.168.10.113:11434/api/version` | `200` |
| lenovo | the same | no answer: curl exit 28 (timeout), `000`, because the firewall drops |
| msi-ms7758 | the same | exit 28, `000` |
| black-pi | the same, and `curl -s -m 5 http://192.168.10.113:9835/metrics \| head -1` | 11434: exit 28; 9835: metrics lines |

"Existing Pi/cloud/gateway unchanged": the gateway's catalog and pi's default are not touched by any #492 PR; the parity tables show only asus-side hosts moving for the asus PRs. **Needs coordinator** to state it against the gateway.

### Rollback (box 4)
**Documented procedure:**
- `docs/nix-audit-pilot.md` ("## Rollback"): "On one host: `sudo nixos-rebuild switch --rollback`, or pick the previous generation in the boot menu (systemd-boot; GRUB on msi-ms7758)". asus also boots GRUB (dual boot; `boot.loader.systemd-boot.enable = false`), so the boot-menu path there is GRUB's.
- **Automatic path:** deploy-rs with `autoRollback = true` and `magicRollback = true` (`flake-modules/deploy.nix`), plus the repo's rollback-before-cancel patch. A failed activation reactivates the previous generation; see #511's PR text for the code path.

**Evidence that exists (read-only):** the system profile's generations on asus, all present, so a rollback target exists:
```
system-14  11-18 16:48  ll5hvc8h…  (current; main e5ba55f4, batch 12)
system-13  11-18 16:10  wfxv449d…  (main 83ade5b7, #551 prompt cache)
system-12  11-18 14:32  0qz74g3j…
system-11  11-18 12:20  q4ad9sk0…
system-10  11-18 11:21  jkr30ic9…
… back to system-2  11-16 15:03 (before the GPU backend)
```
**Not demonstrated:** no rollback has been performed. Today's one failed deploy (main 4ebe13d5, the systemd-verify PIDFile) stopped at dry-activate, before any activation, so nothing was rolled back. A demonstration needs `nixos-rebuild switch --rollback` (or a deliberate failed deploy) on asus and then a switch forward; **that is the owner's decision.**

**Suggested proof once approved:**
1. Note `readlink /run/current-system`.
2. `sudo nixos-rebuild switch --rollback`.
3. Check `/run/current-system` is now system-13's path, Ollama is active, and `ls /var/lib/ollama/models/manifests/registry.ollama.ai/library/` is unchanged.
4. Deploy main again.

**Model cache:**
- `services.ollama.models = "/var/lib/ollama/models"` under the unit's `StateDirectory=ollama`, which systemd keeps across unit changes, outside the Nix store. A switch or rollback does not touch it.
- The only deletion in the module is `modules/homelab/ollama-pull-pinned.sh:13` (`ollama rm "$name"`). That removes a tag only when the registry serves a digest other than its pin, followed by exit 3: a deliberate guard against a moved tag, not cache loss.
- Observed, no re-download: today's 14 loader runs, after each Ollama (re)start including run 2's OOM restart, each took 0.03–4.8 s and received **5.2–7.2 KB** (systemd's `incoming IP traffic`).
  - The `pulling <layer>: 100%` lines they print for gemma4:e4b's 986 MB and 3.3 GB layers are `ollama pull` listing layers it already has. No layer was fetched.
  - That the loader still calls `pull` for that one tag, instead of skipping it as "at its pin", is worth a look by whoever owns `ollama-pull-pinned.sh`. It costs seconds, not data.

## #493 (PoC B): the boxes as written

| # | box (verbatim) | evidence | status |
|---|---|---|---|
| 1 | Run one command against the known MSI baseline and ASUS … and obtain self-describing, repeatable results with fixed input and sample counts. | `scripts/ollama-g1-bench.sh` (fixed fixture at a pinned commit, fixed sampling, nonce per request) and `llm-bench capacity` / `import-g1` (#504); ASUS runs today: g1-result, g1-stress runs 1–3. MSI was not run from asus (its Ollama admits acer only) | **needs coordinator** (the MSI half, from acer) |
| 2 | Real ASUS GPU memory, utilization, power, temp appear in existing Prometheus/Grafana; quote exact PromQL, dashboard panel values and `up` query. >=99% scrape success during a 2h known-on test | The exporter is live on asus (`nvidia_smi_*`, 21 series: memory used/total bytes, `utilization_gpu_ratio`, `power_draw_watts`, `temperature_gpu`, `gpu_info{name="NVIDIA GeForce RTX 3070",driver_version="595.104.02"}`). Prometheus is not reachable from asus, so the queries are below | **needs coordinator** (run the queries; then met/not met on ≥ 0.99) |
| 3 | Latency and throughput clearly separate backend vs gateway, warm vs cold, 4K vs 8K; p50/p95 only if enough samples and are labeled otherwise. | backend, warm vs cold, 4K vs 8K: all in `g1-result.md` and `g1-stress-run.md` (n stated). **Gateway: not measured**; asus is not in the gateway's catalog (llm-gateway#101) | **not met** (the gateway half is missing) |
| 4 | All new Grafana JSON/Prometheus rules validated by repo checks; privacy/cardinality tests; no raw prompts, secrets, tool args or outputs in metrics/logs. | `grafana-dashboards` and `shipping-rules` checks, `llm-bench-test` ("no prompt in an aggregate"), `nav-metrics-test` (no path or prompt in labels), all in today's green gates | **needs coordinator** (to confirm the telemetry dashboard's own panels are in `grafana-dashboards`) |
| 5 | Record baseline table for `qwen2.5-coder:7b`, `llama3.1:8b`, `gemma4:e4b-it-qat`, `gemma4:e2b-it-qat`, `gemma3:4b-it-qat`, `qwen3.5:4b` **where actually runnable**; unavailable/VRAM-offloaded means explicitly rejected, not invented numbers. | table below: three models measured on asus; the other three are not available on asus as deployed | **met for the three pinned models; the other three are explicitly not runnable as deployed (needs owner: pin them or accept the rejection)** |
| 6 | Explain measurement limits (sampling error, GPU-only energy, quantization differences) and attach artifacts to PR/runbook. | limits stated in each result file (sample counts, nearest-rank quantiles, client- vs server-side TTFT, the prompt-cache caveat, GPU-only power from nvidia-smi, the 270 W vs 130 W cap) | **needs coordinator** (attach them to the PR or runbook) |

### Baseline table (box 5): asus-b460m, RTX 3070, Ollama 0.40.3 CUDA, measured today
| model (tag, quant) | 4K decode tok/s p50 | 4K TTFT warm p50/p95 | 8K decode | VRAM 4K / 8K (MiB) | on GPU | cap | source |
|---|---|---|---|---|---|---|---|
| qwen2.5-coder:7b-instruct-q4_K_M (Q4_K_M) | 70.0 (n 400) | 0.952 / 0.971 s | 65.9 (n 10) | 4639 / 4909 | 100 % | 130 W | g1-stress run 3 |
| qwen2.5-coder:7b-instruct-q4_K_M | 75.4 (n 20) | 0.76 / 0.80 s | 71.7 (n 20) | 4639 / 4909 | 100 % | 270 W | g1-result (morning) |
| gemma4:e4b-it-qat (Q4_0) | 87.7 (n 20) | 0.68 / 0.70 s | 85.0 (n 20) | 4247 / 4285 | 100 % | 270 W | g1-result |
| gemma4:e2b-it-qat (Q4_0) | 148.3 (n 20) | 0.41 / 0.41 s | 143.3 (n 20) | 2861 / 3013 | 100 % | 270 W | g1-result |
| llama3.1:8b | **rejected: not available on asus** (not in `homelab.ollama.modelDigests`; pulling it is a config change) | | | | | | |
| gemma3:4b-it-qat | **rejected: not available on asus** (same) | | | | | | |
| qwen3.5:4b | **rejected: not available on asus** (same) | | | | | | |

The 270 W rows were measured before the cap. The 130 W ctx-run (`ctx-result.md`) has e4b and e2b at 4K–128K for comparison. The capacity column (agents) is in `g1-result.md`: qwen 2 agents; gemma4 not evaluable in that run.

### Queries for box 2 (please run on black-pi's Prometheus or in Grafana Explore; I cannot reach it)
Scrape config: `job="nvidia-gpu"`, `scrape_interval` 10s, labels `node="asus-b460m"`, `instance="asus-b460m"`, `sleeps="true"`. **Window:** a 2-hour known-on stretch with load, evaluated at **2026-11-18 16:45:00 CET**, covering 14:45–16:45, which includes stress runs 2 and 3. asus was on and serving throughout; Ollama restarted at 15:22:15 (OOM) and at the 16:10 deploy, but the exporter is a separate unit.
```
up{job="nvidia-gpu",node="asus-b460m"}                                                   # expect 1
avg_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])                                 # box: >= 0.99
count_over_time(up{job="nvidia-gpu",node="asus-b460m"}[2h])                               # expect ~720 samples (10 s)
max_over_time(nvidia_smi_memory_used_bytes{node="asus-b460m"}[2h])                         # expect ~5.15e9 (4909 MiB at 8K)
nvidia_smi_memory_total_bytes{node="asus-b460m"}                                          # 8.589934592e9
max_over_time(nvidia_smi_utilization_gpu_ratio{node="asus-b460m"}[2h])                     # expect ~1.0 under load
avg_over_time(nvidia_smi_utilization_gpu_ratio{node="asus-b460m"}[2h])
max_over_time(nvidia_smi_power_draw_watts{node="asus-b460m"}[2h])                          # expect ~131-133 (130 W cap)
max_over_time(nvidia_smi_temperature_gpu{node="asus-b460m"}[2h])                           # expect ~61
```
**Cross-check from asus's own 1 Hz nvidia-smi log over run 3** (16:10:51–16:42:05): VRAM 4639 MiB steady (4909 at 8K), utilisation p50 98 %, power max 132.8 W, temperature max 61 °C. Prometheus's values for the same window should agree within the 10 s sampling. If `avg_over_time(up…[2h])` comes out below 0.99, the box is **not met**; I have not relaxed it.

## Summary
| | met | not met | needs coordinator | needs owner |
|---|---|---|---|---|
| #492 | 1 (decode); 2 (idle headroom, 8K, 30-min no crash); 4 (systemd recovery; no cache deletion on config); 3 (config) | none | 3 (live connects; gateway unchanged); 5 (links) | 2 (desktop-in-use scenario, or accept idle); 4 (perform a rollback demonstration) |
| #493 | 5 (three pinned models) | 3 (gateway latency not measured) | 1 (MSI half); 2 (run the queries); 4 (dashboard in checks); 6 (attach) | 5 (pin llama3.1:8b, gemma3:4b-it-qat, qwen3.5:4b, or accept their rejection) |
