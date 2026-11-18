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
            # mkDefault: #492's own choice for asus wins
            hardware.nvidia.open = lib.mkDefault true;
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
    "nvidia_smi_power_limit_watts"
    "nvidia_smi_fan_speed_ratio"
    "nvidia_smi_clocks_throttle_reasons_active"
    "nvidia_smi_clocks_throttle_reasons_hw_thermal_slowdown"
    "nvidia_smi_clocks_throttle_reasons_sw_power_cap"
    "nvidia_smi_gpu_info"
  ];
  # every tag a host's Ollama loads must be a model the scorecard's rules accept, or committing its result would fail
  # black-pi's evaluation
  unlisted = lib.concatLists (
    lib.mapAttrsToList (
      name: h:
      map (m: "${name}: ${m}") (
        lib.subtractLists (import ../pkgs/llm-bench/models.nix) (
          lib.optionals h.config.services.ollama.enable h.config.services.ollama.loadModels
        )
      )
    ) config.flake.nixosConfigurations
  );
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
  renders =
    r: (builtins.tryEval (builtins.deepSeq (render { "bad.json" = fixture.fit // r; }) true)).success;
  # GpuTelemetryDown (modules/homelab/monitoring/rules/homelab.yaml): asus's GPU exporter down is a page only while asus
  # itself answers
  gpuTests = {
    rule_files = [ "${../modules/homelab/monitoring/rules/homelab.yaml}" ];
    tests =
      map
        (
          {
            name,
            node,
            gpu,
            firing,
          }:
          {
            inherit name;
            interval = "1m";
            input_series = [
              {
                series = ''up{job="node-exporter",node="asus-b460m",instance="asus-b460m",sleeps="true"}'';
                values = "${node}x30";
              }
              {
                series = ''up{job="nvidia-gpu",node="asus-b460m",instance="asus-b460m",sleeps="true"}'';
                values = "${gpu}x30";
              }
            ];
            promql_expr_test = [
              {
                expr = ''count by (node) (ALERTS{alertname="GpuTelemetryDown",alertstate="firing"})'';
                eval_time = "20m";
                exp_samples = lib.optional firing {
                  labels = ''{node="asus-b460m"}'';
                  value = 1;
                };
              }
            ];
          }
        )
        [
          {
            name = "asus up, its GPU exporter down";
            node = "1";
            gpu = "0";
            firing = true;
          }
          {
            name = "asus off";
            node = "0";
            gpu = "0";
            firing = false;
          }
          {
            name = "asus up, its GPU exporter up";
            node = "1";
            gpu = "1";
            firing = false;
          }
        ];
  };
  badLabels = lib.filter renders [
    { model = "unlisted:70b"; }
    { host = "not-a-fleet-host"; }
    { ctx = 2048; }
    { quant = "Q2_K"; }
    { evidence = "invented"; }
  ];
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
          )) "llm-bench: the GPU exporter does not run its host driver's nvidia-smi (${discard exec})";
          assert lib.assertMsg (lib.hasPrefix "${discard "${pkgs.prometheus-nvidia-gpu-exporter}"}/bin/" (
            lib.trim (discard exec)
          )) "llm-bench: the GPU exporter on the host is not this check's prometheus-nvidia-gpu-exporter";
          pkgs.runCommand "gpu-telemetry-exporter"
            {
              # the command line without its context, so the unfree, uncached driver is never built here; the exporter
              # it names is this package (asserted above)
              nativeBuildInputs = [
                pkgs.python3
                pkgs.curl
                pkgs.prometheus-nvidia-gpu-exporter
              ];
            }
            ''
              printf '#!/bin/sh\nexec python3 -I ${../pkgs/llm-bench/fixtures/fake-nvidia-smi.py} "$@"\n' > nvidia-smi
              chmod +x nvidia-smi
              # the deployed command line, with only the listener and nvidia-smi swapped for the sandbox's
              ${
                lib.replaceStrings
                  [ (discard smi) "${gpuHost.services.prometheus.exporters.nvidia-gpu.listenAddress}:" ]
                  [ "$PWD/nvidia-smi" "127.0.0.1:" ]
                  (lib.replaceStrings [ "\\\n" "\n" ] [ " " " " ] (discard exec))
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
          assert lib.assertMsg (
            unlisted == [ ]
          ) "llm-bench: hosts load tags pkgs/llm-bench/models.nix does not list: ${toString unlisted}";
          assert lib.assertMsg (
            renders { } && badLabels == [ ]
          ) "llm-bench: results with labels outside rules.nix's sets rendered: ${builtins.toJSON badLabels}";
          pkgs.runCommand "llm-bench-scorecard"
            {
              nativeBuildInputs = [ pkgs.prometheus.cli ];
              rules = builtins.toJSON (render {
                "fit.json" = fixture.fit;
                "capacity.json" = fixture.capacity;
              });
              tests = builtins.toJSON ruleTests;
              gpuTests = builtins.toJSON gpuTests;
              passAsFile = [
                "rules"
                "tests"
                "gpuTests"
              ];
            }
            ''
              cp "$rulesPath" rules.yaml
              cp "$testsPath" tests.yaml
              promtool check rules rules.yaml
              promtool test rules tests.yaml
              cp "$gpuTestsPath" gpu-tests.yaml
              promtool test rules gpu-tests.yaml
              touch $out
            '';
      };
    };
}
