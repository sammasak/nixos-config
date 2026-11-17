{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00BL7_S64KNX1T235655")

    ../../modules/hardware/video/intel.nix

    # Default boot mode.
    ../../modules/specialisations/desktop.nix

    # Wake msi (the intermittent LLM worker) on the work-hours schedule.
    ../../modules/homelab/authentik-offhost.nix

    ../../modules/homelab/monitoring/node-exporter.nix
    ../../modules/homelab/journal-collector.nix
    ../../modules/homelab/shipping-metrics.nix
  ];

  # a quarter of the collector's 256M MemoryMax, as the daemon and the user slice: zram is charged to no cgroup
  systemd.services.alloy = lib.mkIf config.homelab.journalCollector.enable {
    serviceConfig.MemorySwapMax = "64M";
  };

  homelab.journalCollector.enable = true;

  sam.profile = {
    username = "lukas";
    hostname = "lenovo-21CB001PMX";
    pi = true;
    nativeOtel = true;
  };
  sam.hostSecrets.enable = true;
  sam.storeCache.enable = true;
  sam.cliTools.factum.enable = true;
  sam.cliTools.nixAudit.enable = true;
  sam.claude.bulkReader.enable = true;
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "claude-code-skills"
    "devenv-platform"
    "factum"
    "herman"
    "knowledge"
    "llm-gateway"
    "nixos-config"
    "rf-proto"
    ".cache/wt"
  ];
  # The worker hosts; their declared nspawn workers are workspaces in the host's Herdr (docs/nspawn-workers.md).
  sam.herdr.machines = [
    {
      label = "acer-swift";
      target = "acer-swift";
    }
    {
      label = "msi-ms7758";
      target = "msi-ms7758";
    }
    {
      label = "asus-b460m";
      target = "asus-b460m";
    }
  ];
  # `ssh <name>.msi` / `ssh <name>.acer` into an environment declared on that host (sam.workers.labelPrefix there).
  sam.workers.jumpHosts = {
    acer = "acer-swift";
    msi = "msi-ms7758";
    asus = "asus-b460m";
  };
  sam.herdr.coordinatorWakeup = {
    enable = true;
    # Delegated approval (the comment every delegated gh:label act cites) and the interactive
    # Coordinator's pane, never a worker nor a handoff target.
    mayApprove = true;
    approvalDecision = "https://github.com/sammasak/skills/issues/28#issuecomment-6629911996";
    panes = [ "lenovo-21CB001PMX/wM:p1" ];
    # No wake session while the interactive Coordinator worked in the last 10 minutes (skills#66).
    interactiveQuietSeconds = 600;
  };

  # As the always-on control plane, lenovo sends every host with a fleet power window its wake.
  sam.powerSchedule.waker.enable = true;

  # Declared here, not in the shared sam.hostSecrets tree, so acer never
  # decrypts the private signing key — it only needs the public half already
  # in nix.settings.trusted-public-keys.
  sops.secrets."nix_signing_key" = {
    sopsFile = ../../secrets/homelab/nix-signing-key.yaml;
    owner = "root";
    mode = "0400";
  };

  # Signs deploy-rs closures pushed to acer, whose trusted-users = [ "root" ]
  # would otherwise reject anything copied in over SSH as lukas.
  nix.settings.secret-key-files = [ config.sops.secrets."nix_signing_key".path ];

  # nixos-config#109: a cold devenv gate builds cargo-semver-checks from source in the daemon,
  # outside every user cgroup and oomd's reach; at cores 8 it peaked at 7.5 GiB plus 1.6 GiB swap
  # on acer, at cores 2 at 6.1 GiB with none. The cap keeps a build from pushing the control plane
  # into zram exhaustion; MemoryHigh throttles first, MemoryMax fails the build, not the host.
  nix.settings = {
    max-jobs = 2;
    cores = 2;
  };
  # The whole memory budget (modules/core/memory-budget.nix): 15.3 GiB of MemTotal; every MemoryMax on the host
  # (these two, and alert-bridge 64M, alloy 256M and node-exporter 64M from their modules) plus the floors fits in it,
  # 115M left. The kernel, page tables and the zram store (about 1 GiB measured) are outside: the caps meet only with
  # the daemon pushed past its MemoryHigh while the user slice is at its ceiling. Swap is a quarter of each cap, as the
  # worker pools: zram is charged to no cgroup.
  sam.memory = {
    ram = "15667M";
    caps = {
      # the measured cores-2 build peak is 6118 MiB with no swap: MemoryHigh throttles first, MemoryMax fails the
      # build, not the host
      "nix-daemon.service" = {
        high = "6G";
        max = "6400M";
        swapMax = "1600M";
      };
      # nixos-config#353: all login users combined, a client-side evaluation included; NOT MemoryHigh, or a runaway
      # stalls every session instead of being killed. The idle sessions' 4.6 GiB that cannot be dropped plus the
      # largest measured unit (3.0 GiB) fit under it (scripts/test-lenovo-build-bounds.py).
      "user.slice" = {
        max = "8448M";
        swapMax = "2112M";
      };
    };
    # the LAN's DNS and the way in keep answering while the user slice and a build are both at their caps
    floors = {
      "adguardhome.service" = "256M";
      "sshd.service" = "64M";
    };
  };

  assertions =
    let
      alloy = config.systemd.services.alloy.serviceConfig;
      mib = v: lib.toInt (lib.removeSuffix "M" (toString v));
    in
    lib.optional config.homelab.journalCollector.enable {
      assertion = mib alloy.MemorySwapMax * 4 <= mib alloy.MemoryMax;
      message = "lenovo: the journal collector's MemorySwapMax ${toString alloy.MemorySwapMax} is above a quarter of its MemoryMax ${toString alloy.MemoryMax}; zram is charged to no cgroup.";
    };

  # pi-harness PICODE_EP and factum FACTS_OLLAMA_EP default to localhost:8080. The
  # llm-gateway serves keyless Ollama only on acer's loopback, so only this reaches it.
  # BatchMode: the unit has no agent, so lukas's key must be usable without one.
  systemd.user.services.ollama-portforward = {
    description = "Forward the llm-gateway keyless Ollama passthrough on acer to localhost:8080";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionUser = config.sam.profile.username;
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.ollama-portforward} http://127.0.0.1:8080/api/tags ${pkgs.openssh}/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -L 127.0.0.1:8080:127.0.0.1:11435 ${config.sam.fleet.hosts.acer-swift.address}";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # ThinkPad-class laptop: thinkfan with the quiet curve instead of thermald.
  sam.thermal.platform = "thinkpad";

  homelab.dns = {
    rewrites = [
      # Wildcard and apex to Caddy on the edge host (modules/homelab/edge.nix). External-DNS
      # writes AdGuard *filtering rules*, not rewrites, which persist under
      # mutableSettings; a stale one could pin a name to the old address. When
      # the repoint landed, external-dns managed no record and user_rules was empty.
      {
        domain = "*.sammasak.dev";
        answer = config.sam.fleet.hosts.${config.sam.fleet.edge}.address;
      }
      {
        domain = "sammasak.dev";
        answer = config.sam.fleet.hosts.${config.sam.fleet.edge}.address;
      }
      {
        domain = "dns.sammasak.dev";
        answer = config.sam.fleet.hosts.${config.networking.hostName}.address;
      } # AdGuard Home on host
    ];
  };

  # Runs outside k8s so paging survives a worker outage. Mobile subscribes to
  # port 2586 on the LAN or Tailscale IP; the web UI is the name below, through Caddy on acer.
  homelab.ntfy.baseUrl = "https://ntfy.sammasak.dev";

  # Alertmanager on black-pi posts to lenovo's LAN address, so loopback is not
  # enough. Pages go to the module's default topic, homelab-alerts.
  homelab.alertBridge = {
    enable = true;
    listenAddress = "0.0.0.0";
    openFirewall = true;
  };

  # secrets/ is edited here, where the personal age key lives (nixos-config's devenv has them too)
  environment.systemPackages = with pkgs; [
    sops
    age
  ];
}
