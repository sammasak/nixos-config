{ config, lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/video/intel.nix
    # Scheduled work-hours power window (self-shutdown half; lenovo does the wake).
    ../../modules/homelab/msi-power-schedule.nix
    ../../modules/homelab/journal-collector.nix
  ];

  # Powered on Mon-Fri ~09:00 (WoL from lenovo) and gracefully shut down at 21:00.
  homelab.msiPowerSchedule.selfShutdown.enable = true;

  # Loki's ClusterIP: reachable only while Cilium is up on msi, until Loki gets a LAN address
  homelab.journalCollector = {
    enable = true;
    lokiUrl = "http://10.43.92.124:3100/loki/api/v1/push";
    ntfyUrl = config.sam.workers.ntfyUrl;
  };

  # 15.9 GiB RAM, ~2.8G of it the host's own: a 10G pool reserves 2G each for at most 5, 3 recommended
  # (docs/nspawn-workers.md, Sizing). No ghHostsFile: msi's lukas has no gh login (git push works over the SSH key).
  sam.workers = {
    # Research partner for the owner: reads, compares and scopes; it does not implement.
    instances.research = {
      model = "claude-fable-5-2";
      prompt = "You are a research partner for the owner of this homelab, not an implementer. Help them research, scope and understand limitations: read code and docs, search the web, compare options with trade-offs, name what is unknown or unverified, and say what a change would cost and risk. Do not implement: no commits, pushes, pull requests, deploys or changes to any system or repository; scratch notes in your home are fine. Cite sources (file paths, URLs) and separate what you verified from what you infer. Keep answers short and lead with the conclusion. Start by greeting the owner and asking what they want to look into.";
    };
    retired = [ "skills91" "boot" "boot2" "mem" "root1" "root2" "gate" "ovl" "ovlr" "ov2" "root3" "perf" "m1" "b1" "b2" ];
    labelPrefix = "msi";
    shutdownNotice = "Mon-Fri 20:40";
    pool.memory = "10G";
  };

  sam.profile = vars;
  # The relay and environments' telemetry only: host sessions here keep their Claude settings (docs/native-otel-canary.md)
  sam.claude.telemetry.enable = false;
  sops.secrets."native_otlp_auth" = lib.mkIf vars.nativeOtel {
    sopsFile = ../../secrets/claude/native-otlp-auth.yaml;
    key = "token";
    mode = "0400";
  };
  sam.herdr.trustedDirs = map (d: "/home/${vars.username}/${d}") [ "nixos-config" ".cache/wt" ];

  # Off at midnight, when the fleet's GC and optimise slots fall, and the runtime-host role drops
  # their catch-up at boot: both run inside the Mon-Fri power window instead.
  nix.gc.dates = lib.mkForce "Mon *-*-01..07 12:00";
  nix.optimise.dates = lib.mkForce [ "Wed 12:00" ];

  # The existing Windows ESP is small. Keep GRUB's mutable directory on root,
  # while leaving only the EFI loader on /boot.
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

  networking.interfaces.enp3s0.wakeOnLan.enable = true;
  systemd.services.wol-enp3s0 = {
    description = "Enable Wake on LAN for enp3s0";
    after = [ "network-addresses-enp3s0.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ethtool}/sbin/ethtool -s enp3s0 wol g";
    };
  };

  # Intermittent (WoL-woken) node: the taint keeps its shutdowns off always-on
  # workloads; CPU/batch jobs opt in via toleration + node-pool. The GTX 680 is
  # Kepler, which current drivers dropped, so the GPU is not wired into k3s.
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium"; # must match control-plane: Cilium KPR, kube-proxy disabled
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
    "--node-taint=sammasak.dev/intermittent=true:NoSchedule"
    # NOTE: no graceful-shutdown args. `shutdownGracePeriod` is a kubelet
    # config-file field, NOT a CLI flag — passing it via --kubelet-arg makes
    # kubelet exit with "unknown flag" and crashloops the node. Not worth a
    # kubelet config file for an opt-in node that runs nothing critical.
  ];
}
