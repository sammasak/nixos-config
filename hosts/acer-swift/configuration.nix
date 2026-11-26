{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-INTEL_SSDPEKNW010T8_BTNH014425J11P0B")

    ../../modules/hardware/video/intel.nix
    ../../modules/homelab/ollama-host.nix
    ../../modules/homelab/open-webui.nix
    ../../modules/homelab/edge.nix
    ../../modules/homelab/llm-gateway.nix
    ../../modules/homelab/authentik.nix
    ../../modules/homelab/exec-pool.nix
    ../../modules/homelab/monitoring/node-exporter.nix
    ../../modules/homelab/nav-metrics.nix
    ../../modules/homelab/shunt-metrics.nix
    ../../modules/homelab/monitoring/alloy-otlp.nix
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/scheduled-gate.nix
  ];

  homelab.journalCollector.enable = true;
  homelab.shuntMetrics.enable = true;
  # the always-on heavy host: msi and asus are off at night
  homelab.scheduledGate.enable = true;
  homelab.llmGateway.asus.enable = true;
  # Shunt on for slot pool1 alone; the host and the other slots stay off, so the collector compares on and off (#625).
  services.devEnvironments.guestModules = [
    (
      { devEnvironment, ... }:
      {
        sam.claude.bulkReader.enable = devEnvironment.name == "pool1";
      }
    )
  ];

  sam.profile = {
    username = "lukas";
    hostname = "acer-swift";
    # herdr host: Pi run viewer panes run pi-view here (devenv-platform#28).
    pi = true;
    nativeOtel = true;
  };
  # pool1 to pool3 reserve 2G each, light pool4 1G; 9G, not 7G: three slots alone filled 7G twice on 25 Nov
  # (docs/nspawn-workers.md, Sizing).
  sam.workers = {
    labelPrefix = "acer";
    pool.memory = "9G";
    ghHostsFile = "/home/${config.sam.profile.username}/.config/gh/hosts.yml";
    # the owner's own `codex login`; codex is offered while it holds one (docs/records/execution-pool-credentials.md)
    codexAuthFile = "/home/${config.sam.profile.username}/.codex/auth.json";
    retired = [
      "herman"
      "a1"
    ];
  };
  homelab.execPool = {
    enable = true;
    roles = [
      "queue"
      "runner"
    ];
    slots = 4;
    # acer already throttles with three busy: pool4's CPUQuota caps its heat at two of the 8 cores, and weight 100
    # against the others' 200 yields to them
    light = {
      slots = 1;
      cpu = 1;
      cpuQuota = "200%";
    };
    agents = [
      "claude"
      "pi"
    ]
    ++ lib.optional (config.sam.workers.codexAuthFile != null) "codex";
    # msi's runner claims from this queue over the fleet LAN (exec-pool-db listener)
    remoteRunners = true;
    monitoring = true;
    ownRefsOnly = true;
    slot.privateUsers = true;
  };
  # the #494 usage spike: the workers' cgroup counters every minute (scripts/guest-records.py --usage)
  services.devEnvironments.records.usage = "1min";
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "claude-code-skills"
    "knowledge"
    "nixos-config"
    ".cache/wt"
  ];

  # Headless shell mode remains the default for the always-on worker. The GUI
  # variant is an explicit boot-menu specialisation for daily laptop use.
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };

  # Power-profiles-daemon still provides the battery-aware system profile; EPP
  # keeps sustained work balanced instead of forcing a power-saving bias.
  sam.thermal.energyPerformancePreference = "balance_performance";

  # WiFi powersave lets the NIC enter deep states, causing ~300-500 ms link
  # drops that break long-lived LAN connections.
  # See vault: homelab/acer-swift-wifi-resilience.md
  networking.networkmanager.wifi.powersave = false;
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0
  '';

  # Defence in depth for what the retry loop cannot reach: NetworkManager
  # wedged, driver stuck, associated but carrying no traffic.
  systemd.services.wifi-selfheal = {
    description = "Reconnect WiFi when the LAN gateway is unreachable (headless self-heal)";
    after = [ "NetworkManager.service" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.iputils
      pkgs.networkmanager
      pkgs.util-linux
    ];
    enableStrictShellChecks = true;
    script = ''
      if ! ping -c3 -W2 ${config.sam.fleet.gateway} >/dev/null 2>&1; then
        logger -t wifi-selfheal "LAN gateway ${config.sam.fleet.gateway} unreachable — bouncing wlp0s20f3"
        nmcli device disconnect wlp0s20f3 || true
        sleep 2
        nmcli device connect wlp0s20f3 || systemctl restart NetworkManager.service
      fi
    '';
  };
  systemd.timers.wifi-selfheal = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "3min";
    };
  };

  services.ollama = {
    enable = true;
    loadModels = [
      "llama3.2:3b"
      "qwen2.5-coder:0.5b"
      "nomic-embed-text:latest"
    ];
    # CPU fallback behind msi: prompts ran at 4.5-6.5 tokens/s (homelab-gitops#253). The default
    # num_ctx: longer prompts are cut to fit, and a request's options.num_ctx still overrides it.
    environmentVariables.OLLAMA_CONTEXT_LENGTH = "4096";
  };
  # the pool full, ollama at its cap and 2.5G for the queue, Authentik and the rest (1.8G with three slots busy, 25 Nov)
  # inside the 15.6 GiB the kernel reports
  assertions = [
    {
      assertion = (config.sam.workers.pool.memory + 4 * 1073741824) / 1048576 + 2560 <= 15974;
      message = "hosts/acer-swift: the workers' pool.memory, Ollama's 4G and 2.5G for the host exceed its 15.6 GiB of RAM.";
    }
  ];
  # One loaded model: llama3.2:3b peaked at 3.1G at a 16K context; 4K needs less.
  systemd.services.ollama.serviceConfig = {
    MemoryMax = "4G";
    CPUQuota = "400%";
  };
}
