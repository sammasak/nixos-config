# Paddock (sammasak/paddock, the asus/ssd-expert-backing serving branch) as a system service: one GGUF on the GPU
# with its MoE experts pinned in host RAM, an OpenAI-style API on the node address. No API key: the bind is
# non-loopback, so Paddock would mint one, and the firewall admits only sam.fleet.listeners.paddock-asus's callers
# (acer's gateway), as for Ollama. The serving recipe: docs/ssd-expert-backing-progress.md on that branch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.paddock;
  listener = config.sam.fleet.listeners.paddock-asus;
  host = config.networking.hostName;
  # power-schedule.nix's unit: the scheduled poweroff starts it, and Paddock stops first
  shutdown = "${lib.head (lib.splitString "-" host)}-scheduled-shutdown.service";
  inherit (config.sam.profile) username;
  # Runs as root (the + prefix): a hardlink, never a copy, so a source on another filesystem fails here instead
  # of filling the disk; a hand-started user unit of the same name holds the GPU and 20 GiB, so it is stopped first.
  stage = pkgs.writeShellScript "paddock-stage" ''
    set -eu
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        config.systemd.package
      ]
    }
    model=${lib.escapeShellArg cfg.model}
    source=${lib.escapeShellArg (toString cfg.modelSource)}
    install -d -m 0755 "$(dirname "$model")"
    if [ ! -e "$model" ]; then
      if [ -z "$source" ] || [ ! -f "$source" ]; then
        echo "paddock: $model is missing and homelab.paddock.modelSource ('$source') is not a file; stage the GGUF" >&2
        exit 1
      fi
      ln "$source" "$model" || {
        echo "paddock: cannot hardlink $source to $model (another filesystem?); not copying it" >&2
        exit 1
      }
    fi
    chmod a+r "$model"
    if systemctl --user --machine=${username}@ is-active --quiet paddock-serve.service 2>/dev/null; then
      echo "paddock: stopping ${username}'s user unit paddock-serve, which holds the GPU"
      systemctl --user --machine=${username}@ stop paddock-serve.service
    fi
  '';
  settings = (pkgs.formats.toml { }).generate "paddock.toml" {
    host = config.sam.fleet.hosts.${host}.address;
    inherit (listener) port;
    inherit (cfg) model;
    max_ctx = cfg.contextLength;
    max_batch = 1;
    no_auth = true;
    vram_budget = 7500;
    # the default 8192-row chunk's scratch leaves the 8 GB card no VRAM for the expert slot cache
    prefill_chunk_rows = 1024;
    moe_offload.enabled = true;
  };
in
{
  options.homelab.paddock = {
    enable = lib.mkEnableOption "Paddock serving one model to acer's gateway (sam.fleet.listeners.paddock-asus)";
    model = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/paddock-models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
      description = "The GGUF Paddock serves; its file stem is the model id /v1/models reports.";
    };
    modelSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "A GGUF on the same filesystem that the service's pre-start hardlinks to `model` while `model` is missing (nothing downloads it).";
    };
    contextLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32768;
      description = "max_ctx. 32768 is what fits the 8 GB card with the pinned experts (14 slots a layer); llm-gateway-asus.toml's context_window must match it.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${dirOf cfg.model} 0755 root root -" ];

    # Paddock takes 6.9 of the card's 8 GiB and allocates as it serves: Ollama on the CPU leaves the GPU to it alone
    # (https://docs.ollama.com/gpu, "an invalid GPU ID"), and the gateway's Ollama model still answers, slower
    services.ollama.environmentVariables.CUDA_VISIBLE_DEVICES = "-1";

    systemd.services.paddock = {
      description = "Paddock: a MoE model on the GPU, experts pinned in RAM, for acer's gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nvidia-persistenced.service"
        "nvidia-power-limit.service"
      ];
      # stopped (SIGTERM drains the request in flight) before the poweroff starts, not raced by it
      conflicts = [ shutdown ];
      before = [ shutdown ];
      # a missing model or a failed bind fails three times and stays failed, not a restart loop
      unitConfig = {
        StartLimitIntervalSec = 600;
        StartLimitBurst = 3;
      };
      environment = {
        # cudarc dlopens libcuda.so by name; on NixOS only this directory has it
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        RUST_LOG = "info";
        PADDOCK_DATA = "/var/lib/paddock";
        XDG_RUNTIME_DIR = "/run/paddock";
      };
      serviceConfig = {
        ExecStartPre = "+${stage}";
        ExecStart = "${lib.getExe pkgs.paddockRunner} --config ${settings} --kernel-pack ${pkgs.paddockCudaSm86}/lib/paddock/pd-cuda-sm86.so";
        Restart = "on-failure";
        RestartSec = 30;
        # load 20 s, warm-up 2.3 s on asus
        TimeoutStartSec = "5min";
        TimeoutStopSec = "60s";
        DynamicUser = true;
        StateDirectory = "paddock";
        RuntimeDirectory = "paddock";
        WorkingDirectory = "/var/lib/paddock";
        # 18.3 GiB of page-locked experts, 0.4 GiB anonymous; up to the cap the GGUF's page cache, reclaimable.
        # memory.peak was 26.0 GiB under this cap; the host budgets the rest (hosts/asus-b460m/configuration.nix, the RAM assertion).
        MemoryMax = "26G";
        MemorySwapMax = 0;
        OOMScoreAdjust = 500;
        CPUQuota = "800%";
        # nixpkgs' services.ollama sandbox, which runs CUDA on this host
        CapabilityBoundingSet = [ "" ];
        DeviceAllow = [
          "char-nvidiactl"
          "char-nvidia-caps"
          "char-nvidia-frontend"
          "char-nvidia-uvm"
        ];
        DevicePolicy = "closed";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = false;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "all";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service @resources"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    assertions = [
      {
        assertion = listener.host == host;
        message = "modules/homelab/paddock.nix: sam.fleet.listeners.paddock-asus serves ${listener.host}, not ${host}; Paddock binds where its listener is.";
      }
      {
        assertion = config.systemd.services ? ${lib.removeSuffix ".service" shutdown};
        message = "modules/homelab/paddock.nix: ${host} has no ${shutdown} (sam.fleet power window), so nothing stops Paddock before its poweroff.";
      }
      {
        assertion = lib.all (i: i == "lo") config.networking.firewall.trustedInterfaces;
        message = "modules/homelab/paddock.nix: a trusted interface bypasses the firewall and reaches Paddock, which serves with no key; trust only loopback.";
      }
    ];
  };
}
