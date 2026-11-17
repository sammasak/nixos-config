{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
  ollama = config.services.ollama;
  acers = [
    config.sam.fleet.hosts.acer-swift.address
  ]
  ++ config.sam.fleet.hosts.acer-swift.extraAddresses;
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
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/ollama-host.nix
    ../../modules/homelab/monitoring/node-exporter.nix
  ];

  homelab.journalCollector = {
    enable = true;
    lokiUrl = "http://${config.sam.fleet.hosts.black-pi.address}:3100/loki/api/v1/push";
    ntfyUrl = config.sam.workers.ntfyUrl;
  };

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

  # Dual boot on Windows' 256 MB ESP, too small for systemd-boot's kernels: as msi, only the GRUB loader goes
  # there, its directory stays on root, and Windows is a hand-written entry (os-prober off).
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
    useOSProber = false;
    configurationLimit = 5;
    mirroredBoots = lib.mkForce [
      {
        path = "/boot-nix";
        efiSysMountPoint = "/boot";
        devices = [ "nodev" ];
      }
    ];
    extraEntries = ''
      menuentry "Windows Boot Manager" {
        insmod part_gpt
        insmod fat
        insmod chain
        search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
      }
    '';
  };

  # Headless RTX 3070 (GA104, Ampere): videoDrivers only selects the driver, X stays off. The open modules are
  # NVIDIA's recommendation from Turing on; the console moves from nouveau to nvidia-drm's framebuffer.
  services.xserver.videoDrivers = [ "nvidia" ];
  # libcuda.so.1 reaches ollama-cuda only via /run/opengl-driver/lib; without it Ollama silently runs on the CPU
  hardware.graphics.enable = true;
  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    nvidiaSettings = false;
  };

  services.ollama = {
    enable = true;
    # GA104 is sm_86: the default ten architectures cost a far longer build for the same runner
    package = pkgs.ollama-cuda.override { cudaArches = [ "sm_86" ]; };
    loadModels = builtins.attrNames config.homelab.ollama.modelDigests;
    # the G1 headroom gate's context; the 8K runs pass options.num_ctx
    environmentVariables.OLLAMA_CONTEXT_LENGTH = "4096";
  };
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
  networking.firewall = {
    inherit
      (mkDualBackendFirewall {
        nftComment = "Ollama answers the llm-gateway on acer only.";
        ports = [ config.services.ollama.port ];
        sources = acers;
        interfaces = [ ];
        backend = config.networking.firewall.backend;
      })
      extraInputRules
      extraCommands
      ;
  };

  assertions = [
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

  networking.interfaces.eno1.wakeOnLan.enable = true;
  systemd.services.wol-eno1 = {
    description = "Enable Wake on LAN for eno1";
    after = [ "network-addresses-eno1.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s eno1 wol g";
    };
  };
}
