#!/usr/bin/env bash
# G1 bench for an Ollama host (#492): a fixed prompt and fixed sampling, one JSON line per request with Ollama's own
# timings (timing_source provider_reported) plus the client wall clock. With CLIENTS > 1 that many closed-loop clients
# each send WARM requests at once: with OLLAMA_NUM_PARALLEL=1 they queue, and ttft_queued_s (wall minus the provider's
# decode time) is the TTFT a client sees, queue wait included.
# usage: ollama-g1-bench.sh HOST MODEL CTX COLD WARM OUT.jsonl [CLIENTS]
# Needs curl, jq, awk and git; the fixture is read from this checkout at a pinned commit.
set -euo pipefail
host=$1 model=$2 ctx=$3 cold=$4 warm=$5 out=$6 clients=${7:-1}
# OLLAMA_URL: another endpoint than HOST's Ollama, for scripts/test-llm-bench.py's fake
url=${OLLAMA_URL:-http://$host:11434}
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
fixture=4171289cc43725ffa4f4009df9b2a4e1d9606d5f

# The same bytes on every host: about 3/4 of the context as prompt, the rest for the KV cache and 256 output tokens.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
  echo "Review the following Nix modules. List every option that opens a network port and the source it admits."
  for f in modules/homelab/ollama-host.nix modules/homelab/llm-gateway.nix lib/firewall.nix modules/core/network.nix modules/core/system.nix modules/homelab/journal-collector.nix; do
    git -C "$repo" show "$fixture:$f"
  done
} > "$work/all"
head -c $((ctx * 9 / 4)) "$work/all" > "$work/prompt"
prompt_sha=$(sha256sum "$work/prompt" | cut -d' ' -f1)
jq -n --arg m "$model" --rawfile p "$work/prompt" --argjson ctx "$ctx" \
  '{model:$m, prompt:$p, stream:false, keep_alive:"10m",
    options:{num_ctx:$ctx, num_predict:256, temperature:0, top_k:1, seed:42}}' > "$work/req"

unload() { curl -fsS "$url/api/generate" -d "{\"model\":\"$model\",\"keep_alive\":0}" > /dev/null; sleep 3; }
run() {
  local kind=$1 i=$2 client=$3 dest=$4 t0 t1 resp ps
  # a nonce line first: Ollama's prompt cache would otherwise serve every warm run's prefill from the last one, and
  # ttft_s (load + prompt eval) would measure nothing; prompt_sha256 stays the fixed prompt's
  jq --arg n "Run $kind-$i-$client." '.prompt = $n + "\n" + .prompt' "$work/req" > "$work/req-$client"
  t0=$(date +%s.%N)
  resp=$(curl -fsS "$url/api/generate" -d @"$work/req-$client")
  t1=$(date +%s.%N)
  ps=$(curl -fsS "$url/api/ps")
  jq -nc --arg host "$host" --arg model "$model" --arg kind "$kind" --argjson i "$i" --argjson ctx "$ctx" \
    --argjson clients "$clients" --argjson client "$client" --arg prompt_sha "$prompt_sha" \
    --argjson t0 "$t0" --argjson t1 "$t1" --argjson r "$resp" --argjson ps "$ps" '
    ($ps.models[] | select(.name == $model)) as $p |
    {host:$host, model:$model, digest:$p.digest, quant:$p.details.quantization_level, ctx:$ctx, kind:$kind, i:$i,
     clients:$clients, client:$client, t_start:$t0, t_end:$t1,
     prompt_sha256:$prompt_sha, sampling:"temp0 top_k1 seed42 num_predict256",
     prompt_tokens:$r.prompt_eval_count, decode_tokens:$r.eval_count,
     load_s:($r.load_duration/1e9), prompt_eval_s:($r.prompt_eval_duration/1e9), decode_s:($r.eval_duration/1e9),
     ttft_s:(($r.load_duration + $r.prompt_eval_duration)/1e9), total_s:($r.total_duration/1e9), wall_s:($t1 - $t0),
     ttft_queued_s:(($t1 - $t0) - $r.eval_duration/1e9),
     prompt_tok_s:($r.prompt_eval_count/($r.prompt_eval_duration/1e9)), decode_tok_s:($r.eval_count/($r.eval_duration/1e9)),
     size:$p.size, size_vram:$p.size_vram, gpu_share:(if $p.size > 0 then $p.size_vram/$p.size else null end),
     timing_source:"provider_reported"}' >> "$dest"
}

curl -fsS "$url/api/version" > /dev/null
for i in $(seq 1 "$cold"); do unload; run cold "$i" 1 "$out"; done
run warmup 0 1 "$out"
for c in $(seq 1 "$clients"); do
  (for i in $(seq 1 "$warm"); do run warm "$i" "$c" "$work/client-$c"; done) &
done
wait
cat "$work"/client-* >> "$out"

# Summary of this file: p50/p95 by nearest rank, sample counts stated.
jq -s '
  def q($p): sort | .[((length * $p) | ceil) - 1];
  group_by([.kind, .clients, .ctx])[] | select(.[0].kind != "warmup") |
  {kind:.[0].kind, model:.[0].model, ctx:.[0].ctx, clients:.[0].clients, n:length,
   decode_tok_s_p50:(map(.decode_tok_s)|q(0.5)), ttft_s_p50:(map(.ttft_s)|q(0.5)), ttft_s_p95:(map(.ttft_s)|q(0.95)),
   ttft_queued_s_p95:(map(.ttft_queued_s)|q(0.95)), load_s_p50:(map(.load_s)|q(0.5)), gpu_share_min:(map(.gpu_share)|min)}' "$out"
