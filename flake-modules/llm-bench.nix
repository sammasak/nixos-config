# The local-inference benchmark (pkgs/llm-bench, nixos-config#493): the harness as a package, and two checks.
# gpu-telemetry-exporter runs asus's exporter command, seeded with a driver, against a fake nvidia-smi that answers as the
# 595 driver does: the exporter refuses a field it does not know at start, and the metric names the scorecard and the
# dashboard read must appear. Whether the real driver accepts every field shows only live, after #492.
# llm-bench-scorecard renders a fixture result to rules and runs promtool on them: exact series, a missing value gives
# none, and a label outside the declared sets fails evaluation.
{ config, lib, ... }:
let
  inherit (config.flake.nixosConfigurations) asus-b460m;
  seeded =
    (asus-b460m.extendModules {
      modules = [
        (
          { lib, ... }:
          {
            homelab.gpuTelemetry.enable = true;
            services.xserver.videoDrivers = [ "nvidia" ];
            hardware.nvidia.open = true;
            nixpkgs.config.allowUnfreePredicate = lib.mkForce (_: true);
          }
        )
      ];
    }).config;
  # once asus sets the fact itself (after #492), the check reads its own driver and flags, not the seed's
  gpuHost = if asus-b460m.config.homelab.gpuTelemetry.enable then asus-b460m.config else seeded;
  exec = gpuHost.systemd.services.prometheus-nvidia-gpu-exporter.serviceConfig.ExecStart;
  smi = "${gpuHost.hardware.nvidia.package.bin}/bin/nvidia-smi";
  discard = builtins.unsafeDiscardStringContext;
  # the exporter's names for the fields the scorecard (llm_bench.py) and the dashboard read
  needed = [
    "nvidia_smi_memory_used_bytes"
    "nvidia_smi_memory_free_bytes"
    "nvidia_smi_memory_total_bytes"
    "nvidia_smi_utilization_gpu_ratio"
    "nvidia_smi_temperature_gpu"
    "nvidia_smi_power_draw_watts"
    "nvidia_smi_clocks_throttle_reasons_active"
    "nvidia_smi_gpu_info"
  ];
  fixture = lib.importJSON ../pkgs/llm-bench/fixtures/scorecard-fixture.json;
  render =
    results:
    import ../pkgs/llm-bench/rules.nix {
      inherit lib results;
      hosts = lib.attrNames asus-b460m.config.sam.fleet.hosts;
      extraHosts = [ "mock-host" ];
      extraModels = [ "mock:7b" ];
    };
  base = {
    host = "mock-host";
    model = "mock:7b";
    quant = "Q4_K_M";
    ctx = "4096";
    evidence = "measured";
  };
  sample = labels: value: {
    labels = "{${
      lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${builtins.toJSON v}") (base // labels))
    }}";
    inherit value;
  };
  expect = expr: samples: {
    inherit expr;
    eval_time = "1m";
    exp_samples = samples;
  };
  ruleTests = {
    rule_files = [ "rules.yaml" ];
    tests = [
      {
        interval = "1m";
        promql_expr_test = [
          (expect "llm_bench:vram_bytes" [
            (sample {
              __name__ = "llm_bench:vram_bytes";
              phase = "steady";
            } 7516192768)
          ])
          (expect "llm_bench:vram_headroom_bytes" [
            (sample { __name__ = "llm_bench:vram_headroom_bytes"; } 1073741824)
          ])
          (expect "llm_bench:decode_tokens_per_second" [
            (sample {
              __name__ = "llm_bench:decode_tokens_per_second";
              stat = "p50";
            } 20.5)
          ])
          # p95 had 4 samples: no series, not 0
          (expect "llm_bench:ttft_seconds" [
            (sample {
              __name__ = "llm_bench:ttft_seconds";
              start = "warm";
              quantile = "0.5";
            } 0.5)
          ])
          (expect "llm_bench:fit" [ (sample { __name__ = "llm_bench:fit"; } 0) ])
          (expect "llm_bench:fit_check" [
            (sample {
              __name__ = "llm_bench:fit_check";
              check = "decode";
            } 0)
            (sample {
              __name__ = "llm_bench:fit_check";
              check = "headroom";
            } 1)
          ])
          (expect "llm_bench:agent_capacity" [
            (sample {
              __name__ = "llm_bench:agent_capacity";
              route = "direct";
            } 3)
          ])
        ];
      }
    ];
  };
  badLabel = builtins.tryEval (
    builtins.deepSeq (render {
      "bad.json" = fixture.fit // {
        model = "unlisted:70b";
      };
    }) true
  );
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.llm-bench = pkgs.writeShellApplication {
        name = "llm-bench";
        runtimeInputs = [ pkgs.python3 ];
        text = ''exec python3 -I ${../pkgs/llm-bench}/llm_bench.py "$@"'';
      };
      checks = {
        gpu-telemetry-exporter =
          assert lib.assertMsg (lib.hasInfix "--nvidia-smi-command ${discard smi} " (
            discard exec
          )) "llm-bench: the GPU exporter does not run its host driver's nvidia-smi (${exec})";
          pkgs.runCommand "gpu-telemetry-exporter"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.curl
              ];
            }
            ''
              printf '#!/bin/sh\nexec python3 -I ${../pkgs/llm-bench/fixtures/fake-nvidia-smi.py} "$@"\n' > nvidia-smi
              chmod +x nvidia-smi
              # the deployed command line, with only the listener and nvidia-smi swapped for the sandbox's
              ${
                lib.replaceStrings
                  [ smi "${gpuHost.services.prometheus.exporters.nvidia-gpu.listenAddress}:" ]
                  [ "$PWD/nvidia-smi" "127.0.0.1:" ]
                  (lib.replaceStrings [ "\\\n" "\n" ] [ " " " " ] exec)
              } > exporter.log 2>&1 &
              exporter=$!
              for _ in $(seq 50); do curl -fsS -o metrics http://127.0.0.1:${toString gpuHost.services.prometheus.exporters.nvidia-gpu.port}/metrics && break; sleep 0.2; done
              cat exporter.log
              for m in ${lib.concatStringsSep " " needed}; do
                grep -q "^$m{" metrics || { echo "gpu-telemetry-exporter: no $m in the exporter's output" >&2; exit 1; }
              done
              kill "$exporter"
              grep '^nvidia_smi_' metrics > $out
            '';
        llm-bench-scorecard =
          assert lib.assertMsg (!badLabel.success)
            "llm-bench: a result naming an undeclared model rendered; the label sets in rules.nix no longer bound it";
          pkgs.runCommand "llm-bench-scorecard"
            {
              nativeBuildInputs = [ pkgs.prometheus.cli ];
              rules = builtins.toJSON (render {
                "fit.json" = fixture.fit;
                "capacity.json" = fixture.capacity;
              });
              tests = builtins.toJSON ruleTests;
              passAsFile = [
                "rules"
                "tests"
              ];
            }
            ''
              cp "$rulesPath" rules.yaml
              cp "$testsPath" tests.yaml
              promtool check rules rules.yaml
              promtool test rules tests.yaml
              touch $out
            '';
      };
    };
}
