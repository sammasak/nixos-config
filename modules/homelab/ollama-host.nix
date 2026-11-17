# services.ollama for the llm-gateway, bound to the node address. The port is opened to no source, so the LAN is
# dropped unless the host adds a scoped rule. The host sets the models, the context and the MemoryMax that fits one
# loaded model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/firewall.nix lib) anySourceTcp;
  cfg = config.services.ollama;
  fw = config.networking.firewall;
  pins = config.homelab.ollama.modelDigests;
  pullPinned = pkgs.writeShellApplication {
    name = "ollama-pull-pinned";
    runtimeInputs = [
      cfg.package
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ./ollama-pull-pinned.sh;
  };
in
{
  options.homelab.ollama.modelDigests = lib.mkOption {
    type = lib.types.attrsOf (lib.types.strMatching "[0-9a-f]{64}");
    default = { };
    description = "Pins each services.ollama.loadModels tag to its registry manifest sha256 (the digest /api/tags reports). With any pin set, the loader leaves a tag already at its pin unpulled, and when the registry serves another digest it removes the tag and fails.";
  };

  config = lib.mkIf cfg.enable {
    services.ollama = {
      host = config.sam.fleet.hosts.${config.sam.profile.hostname}.address;
      environmentVariables = {
        # one model and one request at a time: the host's MemoryMax is sized for that
        OLLAMA_MAX_LOADED_MODELS = "1";
        OLLAMA_NUM_PARALLEL = "1";
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_KV_CACHE_TYPE = "q8_0";
        OLLAMA_KEEP_ALIVE = "5m";
      };
    };
    # The bind needs the node address: wait for it at boot, then keep retrying if it comes later
    # (acer's is on Wi-Fi). No start limit: the model loader's restarts start this unit at once,
    # past RestartSec, so three failed binds would otherwise leave it failed for good.
    systemd.services.ollama = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.StartLimitIntervalSec = 0;
    };
    # an OOM takes Ollama before any worker
    systemd.services.ollama.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
      MemorySwapMax = 0;
      OOMScoreAdjust = 1000;
    };

    # A tag already at its pin is never pulled again, so a moved upstream tag cannot replace it. Exit 3 is a moved
    # tag, removed again: no restart, the unit stays failed and the host degraded until the pin is reviewed.
    systemd.services.ollama-model-loader = lib.mkIf (pins != { }) {
      script = lib.mkForce "exec ${lib.getExe pullPinned} ${
        lib.escapeShellArgs (lib.mapAttrsToList (name: digest: "${name} ${digest}") pins)
      }";
      serviceConfig.RestartPreventExitStatus = 3;
    };

    assertions = [
      {
        assertion = pins == { } || lib.sort lib.lessThan cfg.loadModels == lib.attrNames pins;
        message = "modules/homelab/ollama-host.nix: with homelab.ollama.modelDigests set, pin every services.ollama.loadModels tag and nothing else; unpinned: ${toString (lib.subtractLists (lib.attrNames pins) cfg.loadModels)}, not loaded: ${toString (lib.subtractLists cfg.loadModels (lib.attrNames pins))}.";
      }
      {
        assertion = fw.enable && !cfg.openFirewall && anySourceTcp fw [ cfg.port ] == [ ];
        message = "modules/homelab/ollama-host.nix: Ollama has no authentication; keep the firewall on, openFirewall off and port ${toString cfg.port} out of allowedTCPPorts and allowedTCPPortRanges, global and per interface. Admit a caller with a source-scoped rule.";
      }
      {
        assertion = lib.all (i: i == "lo") fw.trustedInterfaces;
        message = "modules/homelab/ollama-host.nix: a trusted interface bypasses the firewall and reaches Ollama; trust only loopback, not ${toString (lib.remove "lo" fw.trustedInterfaces)}.";
      }
      {
        # libggml-cuda.so loads libcuda.so.1 from /run/opengl-driver/lib alone; without it Ollama serves on the CPU
        assertion =
          !lib.any (p: lib.getName p == "cuda_cudart") cfg.package.buildInputs
          || config.hardware.graphics.enable;
        message = "modules/homelab/ollama-host.nix: ${cfg.package.name} is a CUDA build; set hardware.graphics.enable = true, or Ollama finds no libcuda.so.1 and silently runs on the CPU.";
      }
      {
        assertion = config.systemd.services.ollama.serviceConfig ? MemoryMax;
        message = "modules/homelab/ollama-host.nix: set systemd.services.ollama.serviceConfig.MemoryMax to what one loaded model needs.";
      }
    ];
  };
}
