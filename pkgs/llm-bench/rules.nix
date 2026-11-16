# llm-bench results (./scorecard, written by llm_bench.py and committed after review) as constant recording rules for
# black-pi's Prometheus: the model-fit table and the agent capacity next to the live series. Labels are bounded by the
# lists below, so a result naming anything else fails evaluation; a null value gives no series, never 0.
{
  lib,
  hosts,
  results,
  # the gate's fixture adds its own host and model
  extraHosts ? [ ],
  extraModels ? [ ],
}:
let
  models = import ./models.nix ++ extraModels;
  quants = [
    "Q4_0"
    "Q4_K_S"
    "Q4_K_M"
    "Q5_K_M"
    "Q6_K"
    "Q8_0"
    "F16"
    "unknown"
  ];
  allowed = {
    host = hosts ++ extraHosts;
    model = models;
    quant = quants;
    # 16384: msi's archived runs (llm_bench.py import-msi), not a fit context
    ctx = [
      "4096"
      "8192"
      "16384"
    ];
    evidence = [
      "measured"
      "historical"
    ];
    route = [
      "direct"
      "gateway"
    ];
    check = [
      "headroom"
      "offload"
      "decode"
      "ttft"
      "cold_load"
    ];
  };
  check =
    file: labels:
    let
      bad =
        lib.filterAttrs (k: v: allowed ? ${k} && !lib.elem v allowed.${k}) labels
        // lib.optionalAttrs ((labels.ctx or "") == "16384" && labels.evidence != "historical") {
          inherit (labels) ctx evidence;
        };
    in
    lib.throwIf (
      bad != { }
    ) "llm-bench rules: ${file} has labels outside the declared sets: ${builtins.toJSON bad}" labels;
  value = r: name: (r.metrics.${name} or { }).value or null;
  one =
    labels: record: v: extra:
    lib.optional (v != null) {
      inherit record;
      expr = "vector(${toString v})";
      labels = labels // extra;
    };
  rulesOf =
    file: r:
    let
      base = check file {
        inherit (r) host model evidence;
        quant = if r.quant == null then "unknown" else r.quant;
        ctx = toString r.ctx;
      };
      m = value r;
      fitRules = lib.concatLists [
        (one base "llm_bench:vram_bytes" (m "vram_load_bytes") { phase = "load"; })
        (one base "llm_bench:vram_bytes" (m "vram_steady_bytes") { phase = "steady"; })
        (one base "llm_bench:vram_headroom_bytes" (m "vram_headroom_bytes") { })
        (one base "llm_bench:gpu_offload_ratio" (m "gpu_offload_ratio") { })
        (one base "llm_bench:decode_tokens_per_second" (m "decode_tps_p50") { stat = "p50"; })
        (one base "llm_bench:ttft_seconds" (m "ttft_warm_p50") {
          start = "warm";
          quantile = "0.5";
        })
        (one base "llm_bench:ttft_seconds" (m "ttft_warm_p95") {
          start = "warm";
          quantile = "0.95";
        })
        (one base "llm_bench:ttft_seconds" (m "ttft_cold_p50") {
          start = "cold";
          quantile = "0.5";
        })
        (one base "llm_bench:cold_load_seconds" (m "cold_load_p50") { })
        (one base "llm_bench:gpu_joules_per_output_token" (m "gpu_joules_per_output_token") { })
        (one base "llm_bench:fit" (
          if r.fit == "yes" then
            1
          else if r.fit == "no" then
            0
          else
            null
        ) { })
        (lib.concatLists (
          lib.mapAttrsToList (
            name: c:
            one base "llm_bench:fit_check" (
              if c.pass == null then
                null
              else if c.pass then
                1
              else
                0
            ) (check file { check = name; })
          ) (r.checks or { })
        ))
      ];
      capRules = one base "llm_bench:agent_capacity" (r.capacity.agents or null) (
        check file { inherit (r) route; }
      );
    in
    assert lib.assertMsg (
      r.schema == "llm-bench/1"
    ) "llm-bench rules: ${file} is not an llm-bench/1 result";
    if r.kind == "capacity" then capRules else fitRules;
in
{
  groups = [
    {
      name = "llm_bench.scorecard";
      rules = lib.concatLists (lib.mapAttrsToList rulesOf results);
    }
  ];
}
