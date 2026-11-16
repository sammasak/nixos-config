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
    ../../modules/homelab/msi-power-schedule.nix
    ../../modules/homelab/authentik-offhost.nix

    ../../modules/homelab/monitoring/node-exporter.nix
    ../../modules/homelab/journal-collector.nix
  ];

  # a quarter of the collector's 256M MemoryMax, as the daemon and the user slice: zram is charged to no cgroup
  systemd.services.alloy.serviceConfig.MemorySwapMax = "64M";

  homelab.journalCollector = {
    enable = true;
    lokiUrl = "http://${config.sam.fleet.hosts.black-pi.address}:3100/loki/api/v1/push";
    ntfyUrl = "http://${config.sam.fleet.hosts.lenovo-21CB001PMX.address}:2586/homelab-alerts";
  };

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

  # As the always-on control plane, lenovo sends msi its Mon-Fri 09:00 wake.
  homelab.msiPowerSchedule.waker.enable = true;

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
  # swap a quarter of the cap, as the user slice and the worker pools: zram is charged to no cgroup
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "6G";
    MemoryMax = "7G";
    MemorySwapMax = "1792M";
  };

  # nixos-config#353: the daemon cap does not hold a client-side evaluation. All login users combined;
  # daemon builds sit outside. Closes one runaway only: this plus the daemon cap still exceeds RAM.
  # NOT MemoryHigh: a runaway then never reaches the limit and stalls every session instead (workers/core.nix).
  # RAM less the measured control plane (scripts/test-lenovo-build-bounds.py); swap a quarter, as the worker pools.
  systemd.slices.user.sliceConfig = {
    MemoryMax = "8704M";
    MemorySwapMax = "2176M";
  };

  # The caps still oversubscribe RAM: the user ceiling plus the daemon's MemoryHigh is 14.5 GiB before the kernel,
  # zram and system.slice (about 1.9 GiB measured); MemoryHigh only throttles. Closing that needs the measured floor
  # (#354). These hold what is known: the daemon throttles before its cap, and no swap cap exceeds a quarter of its cap.
  assertions =
    let
      parse =
        v:
        let
          m = builtins.match "([0-9]+)([KMG]?)" (toString v);
        in
        if m == null then
          throw "lenovo: cannot size ${toString v} (want an integer, optionally with K, M or G)"
        else
          lib.toInt (builtins.elemAt m 0)
          * {
            "" = 1;
            K = 1024;
            M = 1048576;
            G = 1073741824;
          }
          .${builtins.elemAt m 1};
      daemon = config.systemd.services.nix-daemon.serviceConfig;
      user = config.systemd.slices.user.sliceConfig;
    in
    [
      {
        assertion = parse daemon.MemoryHigh < parse daemon.MemoryMax;
        message = "lenovo: nix-daemon MemoryHigh ${daemon.MemoryHigh} must be below its MemoryMax ${daemon.MemoryMax}, so a build is throttled before it is killed.";
      }
      {
        assertion = parse daemon.MemorySwapMax * 4 <= parse daemon.MemoryMax;
        message = "lenovo: nix-daemon MemorySwapMax ${daemon.MemorySwapMax} is above a quarter of its MemoryMax ${daemon.MemoryMax}; zram is charged to no cgroup.";
      }
      {
        assertion =
          parse config.systemd.services.alloy.serviceConfig.MemorySwapMax * 4
          <= parse config.systemd.services.alloy.serviceConfig.MemoryMax;
        message = "lenovo: the journal collector's MemorySwapMax is above a quarter of its MemoryMax; zram is charged to no cgroup.";
      }
      {
        assertion = parse user.MemorySwapMax * 4 <= parse user.MemoryMax;
        message = "lenovo: user.slice MemorySwapMax ${user.MemorySwapMax} is above a quarter of its MemoryMax ${user.MemoryMax}; zram is charged to no cgroup.";
      }
    ];

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
      # Wildcard and apex to Caddy on acer (modules/homelab/edge.nix). External-DNS
      # writes AdGuard *filtering rules*, not rewrites, which persist under
      # mutableSettings; a stale one could pin a name to the old address. When
      # the repoint landed, external-dns managed no record and user_rules was empty.
      {
        domain = "*.sammasak.dev";
        answer = config.sam.fleet.hosts.acer-swift.address;
      }
      {
        domain = "sammasak.dev";
        answer = config.sam.fleet.hosts.acer-swift.address;
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
