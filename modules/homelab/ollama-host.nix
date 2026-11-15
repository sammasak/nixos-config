# services.ollama for the llm-gateway on a k3s node, bound to the node address. Pods arrive on the trusted
# Cilium interfaces; the port is opened to no source, so the LAN is dropped unless the host adds a scoped rule.
# A cluster Cilium policy limits pods to the gateway (homelab-gitops #254). The host sets the models, the
# context and the MemoryMax that fits one loaded model.
{ config, lib, ... }:
let
  inherit (import ../../lib/firewall.nix lib) anySourceTcp;
  cfg = config.services.ollama;
  fw = config.networking.firewall;
  cilium = [
    "lo"
    "cilium_host"
    "cilium_net"
    "cilium_vxlan"
    "cilium_health"
    "lxc+"
  ];
in
{
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
    # k3s does not count this unit, so an OOM takes Ollama before any pod or worker.
    systemd.services.ollama.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 5;
      MemorySwapMax = 0;
      OOMScoreAdjust = 1000;
    };

    assertions = [
      {
        assertion = fw.enable && !cfg.openFirewall && anySourceTcp fw [ cfg.port ] == [ ];
        message = "modules/homelab/ollama-host.nix: Ollama has no authentication; keep the firewall on, openFirewall off and port ${toString cfg.port} out of allowedTCPPorts and allowedTCPPortRanges, global and per interface. Admit a caller with a source-scoped rule.";
      }
      {
        assertion = lib.all (i: lib.elem i cilium) fw.trustedInterfaces;
        message = "modules/homelab/ollama-host.nix: a trusted interface bypasses the firewall and reaches Ollama; trust only loopback and Cilium's, not ${toString (lib.subtractLists cilium fw.trustedInterfaces)}.";
      }
      {
        assertion = config.systemd.services.ollama.serviceConfig ? MemoryMax;
        message = "modules/homelab/ollama-host.nix: set systemd.services.ollama.serviceConfig.MemoryMax to what one loaded model needs; k3s does not count this unit.";
      }
    ];
  };
}
