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
  ];

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
  # First host on the shunt hooks (CLAUDE.md, Bulk reader); rollback: false, or SHUNT_DISABLE=1.
  sam.claude.bulkReader.enable = true;
  sam.herdr.trustedDirs = map (d: "/home/${config.sam.profile.username}/${d}") [
    "claude-code-skills"
    "devenv-platform"
    "factum"
    "herman"
    "homelab-gitops"
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
  ];
  # `ssh <name>.msi` / `ssh <name>.acer` into an environment declared on that host (sam.workers.labelPrefix there).
  sam.workers.jumpHosts = {
    acer = "acer-swift";
    msi = "msi-ms7758";
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
  systemd.services.nix-daemon.serviceConfig = {
    MemoryHigh = "6G";
    MemoryMax = "7G";
  };

  # pi-harness PICODE_EP and factum FACTS_OLLAMA_EP default to localhost:8080. The
  # llm-gateway serves keyless Ollama only on its pod loopback, so only this reaches it.
  systemd.user.services.ollama-portforward = {
    description = "Port-forward the llm-gateway keyless Ollama passthrough to localhost:8080";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionUser = config.sam.profile.username;
    environment.KUBECONFIG = "%h/.kube/config";
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.ollama-portforward} http://127.0.0.1:8080/api/tags ${pkgs.kubectl}/bin/kubectl port-forward --address 127.0.0.1 deploy/llm-gateway -n llm 8080:11434";
      Restart = "always";
      RestartSec = 5;
    };
  };

  homelab.flux = {
    enable = true;
    gitUrl = "ssh://git@github.com/sammasak/homelab-gitops";
    gitBranch = "main";
    gitPath = "clusters/homelab";
  };

  homelab.k3s.taintControlPlane = true;

  # ThinkPad-class laptop: thinkfan + thermald with a less heat-prone curve.
  sam.thermal = {
    platform = "thinkpad";
    profile = "quiet";
  };

  homelab.dns = {
    enable = true;
    tls = {
      enable = true;
      domain = "dns.sammasak.dev";
      dohPort = 443;
    };
    rewrites = [
      # Wildcard to the Traefik MetalLB IP. Per-service records from External-DNS
      # are written as AdGuard *filtering rules*, not rewrites, and persist
      # because mutableSettings is true — so they never collide with these.
      {
        domain = "*.sammasak.dev";
        answer = "192.168.10.203";
      }
      {
        domain = "sammasak.dev";
        answer = "192.168.10.203";
      }
      {
        domain = "dns.sammasak.dev";
        answer = config.sam.fleet.hosts.${config.networking.hostName}.address;
      } # AdGuard Home on host
    ];
  };

  homelab.acme = {
    enable = true;
    dnsDomain = "dns.sammasak.dev";
  };

  # Runs outside k8s so paging survives a worker outage. Mobile subscribes to
  # the LAN URL below, or to the same port on the Tailscale IP.
  homelab.ntfy = {
    enable = true;
    baseUrl = "http://${config.sam.fleet.hosts.${config.networking.hostName}.address}:2586";
  };

  # Alertmanager runs in a pod and posts to lenovo's LAN address, so loopback
  # is not enough. The shadow topic keeps pages single while both bridges get
  # every notification; cutover drops ntfyUrl to take the module's default.
  homelab.alertBridge = {
    enable = true;
    listenAddress = "0.0.0.0";
    openFirewall = true;
    ntfyUrl = "http://127.0.0.1:${toString config.homelab.ntfy.port}/homelab-alerts-shadow";
  };

  # Grants non-interactive control-plane deploy — a deliberate trust choice.
  # See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
  homelab.nixosRebuildTrigger.enable = true;
}
