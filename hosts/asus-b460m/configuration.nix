{
  config,
  lib,
  pkgs,
  ...
}:
let
  ollama = config.services.ollama;
  # Ollama's callers (sam.fleet.listeners.ollama-asus), as the firewall check below reads them
  acers = lib.concatMap (
    h: [ config.sam.fleet.hosts.${h}.address ] ++ config.sam.fleet.hosts.${h}.extraAddresses
  ) config.sam.fleet.listeners.ollama-asus.from;
  driver = config.hardware.nvidia.package.version;
  # the CUDA runtime the ollama build links, not the default cudaPackages set
  cuda =
    (
      if config.homelab.ollama.cudaRuntime == null then
        throw "hosts/asus-b460m: homelab.ollama.cudaRuntime finds no cuda_cudart in ollama's buildInputs; fix its predicate in ollama-host.nix"
      else
        config.homelab.ollama.cudaRuntime
    ).version;
  # what activation links /run/opengl-driver to; absent without hardware.graphics, and the check then fails
  driversEnv =
    config.systemd.tmpfiles.settings.graphics-driver."/run/opengl-driver"."L+".argument
      or "/nonexistent";
  # NVIDIA's minimum Linux driver per CUDA major (CUDA Toolkit release notes, table 3)
  minDriver = {
    "12" = "525.60.13";
    "13" = "580.65.06";
  };
  # the iptables backend's script; the workers module requires iptables on asus
  firewallStart = lib.head (
    lib.splitString " " (lib.removePrefix "@" config.systemd.services.firewall.serviceConfig.ExecStart)
  );
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/windows-dual-boot.nix
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/ollama-host.nix
    ../../modules/homelab/monitoring/node-exporter.nix
    ../../modules/homelab/nav-metrics.nix
  ];

  homelab.journalCollector.enable = true;

  # 32 GB RAM, the host's own use not yet measured (msi's 2.8G assumed): a 20G pool reserves 2G each for at most 10,
  # 4 recommended (docs/nspawn-workers.md, Sizing). No ghHostsFile until lukas has a gh login here.
  sam.workers = {
    labelPrefix = "asus";
    pool.memory = "20G";
  };

  sam.profile = {
    username = "lukas";
    hostname = "asus-b460m";
    nativeOtel = true;
  };
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "nixos-config"
    ".cache/wt"
  ];

  # Headless RTX 3070 (GA104, Ampere): videoDrivers only selects the driver, X stays off. The open modules are
  # NVIDIA's recommendation from Turing on; the console moves from nouveau to nvidia-drm's framebuffer.
  services.xserver.videoDrivers = [ "nvidia" ];
  # libcuda.so.1 reaches ollama-cuda only via /run/opengl-driver/lib; without it Ollama silently runs on the CPU
  hardware.graphics.enable = true;
  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    nvidiaSettings = false;
    # headless with no client between model loads: without it the driver may drop the GPU's state, power limit
    # included, until the next load
    nvidiaPersistenced = true;
  };
  # mkForce: nixpkgs' unit names /var/run, which systemd-verify (modules/core/systemd-verify.nix) rejects as legacy;
  # /var/run links to /run, so the daemon still writes the same file
  systemd.services.nvidia-persistenced.serviceConfig.PIDFile =
    lib.mkForce "/run/nvidia-persistenced/nvidia-persistenced.pid";

  services.ollama = {
    enable = true;
    inherit (config.sam.fleet.listeners.ollama-asus) port;
    # GA104 is sm_86: the default ten architectures cost a far longer build for the same runner
    package = pkgs.ollama-cuda.override { cudaArches = [ "sm_86" ]; };
    loadModels = builtins.attrNames config.homelab.ollama.modelDigests;
    # what /v1 clients (pi, llm-bench capacity) get: /v1 drops a request's num_ctx. The G1 bench sets options.num_ctx
    # on every request, so this default never reaches it. At 32K each pinned tag stays fully on the GPU, also right
    # after a swap: qwen 5499 MiB, gemma4:e4b 4609, of the 7833 the driver leaves usable (8192 less 359 reserved).
    environmentVariables.OLLAMA_CONTEXT_LENGTH = "32768";
  };
  # the sweep's knee (qwen2.5-coder 7b, steady load): 75.6 tok/s at 60 C and 70 % fan, against 81.5 at 270 W, 85 C, 100 %
  homelab.ollama.gpuPowerLimit = 130;
  # registry.ollama.ai manifest sha256 per tag, as /api/tags reports it
  homelab.ollama.modelDigests = {
    "qwen2.5-coder:7b-instruct-q4_K_M" =
      "dae161e27b0e90dd1856c8bb3209201fd6736d8eb66298e75ed87571486f4364";
    "gemma4:e4b-it-qat" = "ee665637121887cf3befff38abbb1be4ee117c7db867d97a67e29049ecd7e15f";
    "gemma4:e2b-it-qat" = "07ea59a474013479c8b6b802bef095c40e964a1d776ba02f264c0e30e1aede0c";
  };
  # Host RAM only: the weights sit in VRAM, and cgroups neither cap nor reserve it. 8G holds gemma4:e4b's 6.1G
  # if it falls back to the CPU; CPUQuota keeps such a fallback off the workers' cores.
  systemd.services.ollama.serviceConfig = {
    MemoryMax = "8G";
    CPUQuota = "800%";
  };
  assertions = [
    {
      # the RTX 3070's power.min_limit and power.max_limit; nvidia-smi -pl refuses anything outside them
      assertion =
        config.homelab.ollama.gpuPowerLimit == null
        || (config.homelab.ollama.gpuPowerLimit >= 100 && config.homelab.ollama.gpuPowerLimit <= 270);
      message = "hosts/asus-b460m: homelab.ollama.gpuPowerLimit is ${toString config.homelab.ollama.gpuPowerLimit} W; the RTX 3070 takes 100 to 270 W.";
    }
    {
      assertion =
        minDriver ? ${lib.versions.major cuda}
        && lib.versionAtLeast driver minDriver.${lib.versions.major cuda};
      message = "hosts/asus-b460m: CUDA ${cuda} needs NVIDIA driver ${
        minDriver.${lib.versions.major cuda} or "(unlisted major)"
      } or later, the package is ${driver}.";
    }
    {
      assertion =
        ollama.environmentVariables.OLLAMA_MAX_LOADED_MODELS == "1"
        && ollama.environmentVariables.OLLAMA_NUM_PARALLEL == "1";
      message = "hosts/asus-b460m: PoC A serves one model and one request at a time (OLLAMA_MAX_LOADED_MODELS and OLLAMA_NUM_PARALLEL = 1); VRAM is not shared by any cgroup.";
    }
    {
      # qwen2.5-coder's trained context: above it Ollama clamps to 32768 and silently drops the prompt's head; below
      # 4096 pi's own system prompt and tools (about 2.5K tokens) leave no room for a session
      assertion =
        lib.toInt ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH <= 32768
        && lib.toInt ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH >= 4096;
      message = "hosts/asus-b460m: OLLAMA_CONTEXT_LENGTH is ${ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH}; keep it from 4096 (pi's own prompt is about 2.5K tokens) to 32768 (qwen2.5-coder:7b's trained context, above which Ollama silently truncates).";
    }
  ];
  # The rendered firewall admits the Ollama port from acer and nothing else; the package carries the CUDA runner (a
  # CUDA build missing its toolkit silently ships the CPU runner only), whose RUNPATH holds /run/opengl-driver/lib,
  # and the env activation links there holds libcuda.so.1. It does not prove the sandboxed unit loads it and sees the
  # card: only "library=CUDA" in Ollama's journal after a switch and a restart does.
  system.checks = [
    (pkgs.runCommand "asus-ollama-gpu-check" { nativeBuildInputs = [ pkgs.binutils ]; } ''
      echo "proves: firewall rule, CUDA runner, its RUNPATH, libcuda in the drivers env; not proven: GPU discovery at runtime (journal library=CUDA)"
      rules=$(grep -- '--dport ${toString ollama.port} ' ${firewallStart})
      echo "$rules"
      [ "$(echo "$rules" | wc -l)" = ${toString (lib.length acers)} ]
      ${lib.concatMapStrings (a: ''
        echo "$rules" | grep -q -- '-s ${a} -p tcp --dport ${toString ollama.port} -j nixos-fw-accept'
      '') acers}
      ls ${ollama.package}/lib/ollama/*/libggml-cuda.so
      for so in ${ollama.package}/lib/ollama/*/libggml-cuda.so; do
        readelf -d "$so" | grep -E 'R(UN)?PATH' | grep -q '/run/opengl-driver/lib' \
          || { echo "$so: /run/opengl-driver/lib not in its RUNPATH"; exit 1; }
      done
      [ -e ${driversEnv}/lib/libcuda.so.1 ] \
        || { echo "${driversEnv}: no lib/libcuda.so.1, Ollama would run on the CPU"; exit 1; }
      touch $out
    '')
  ];
}
