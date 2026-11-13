{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hardware/video/intel.nix
    # Scheduled work-hours power window (self-shutdown half; lenovo does the wake).
    ../../modules/homelab/msi-power-schedule.nix
  ];

  # Powered on Mon-Fri ~09:00 (WoL from lenovo) and gracefully shut down at 21:00.
  homelab.msiPowerSchedule.selfShutdown.enable = true;

  # 15.9 GiB RAM, ~2.8G of it the host's own: a 10G pool reserves 2G each for at most 5, 3 recommended
  # (docs/nspawn-workers.md, Sizing). No ghHostsFile: msi's lukas has no gh login (git push works over the SSH key).
  sam.workers = {
    # Research partner for the owner: reads, compares and scopes; it does not implement.
    instances.research = {
      model = "claude-fable-5-2";
      prompt = "You are a research partner for the owner of this homelab, not an implementer. Help them research, scope and understand limitations: read code and docs, search the web, compare options with trade-offs, name what is unknown or unverified, and say what a change would cost and risk. Do not implement: no commits, pushes, pull requests, deploys or changes to any system or repository; scratch notes in your home are fine. Cite sources (file paths, URLs) and separate what you verified from what you infer. Keep answers short and lead with the conclusion. Start by greeting the owner and asking what they want to look into.";
    };
    # Research only, for the owner: what a NATS-based home alerting setup would look like.
    instances.nats = {
      model = "claude-fable-5-2";
      prompt = "You are a research instance for the owner of this homelab. You research and scope; you do not implement: no commits, pushes, pull requests, deploys or changes to any system or repository (scratch notes and throwaway local experiments in your home are fine). Question from the owner: can we take inspiration from https://lovable.dev/blog/lovable-realtime-service to set up our own NATS home alerting setup, and what would it look like? Read that article first and state what it actually built and why. Then learn the current setup: clone git@github.com:sammasak/nixos-config.git and git@github.com:sammasak/homelab-gitops.git read-only into ~/research and read docs/k3s-to-nixos-native.md plus the alerting path (Prometheus and Alertmanager in k3s, a small bridge that posts to ntfy, a native ntfy on lenovo, a cluster watchdog, phone notifications through the ntfy app, also over Tailscale). The fleet is four small NixOS hosts moving services out of k3s to NixOS-native systemd services; the owner wants the right fit without overengineering or hacks, upstream NixOS modules over bespoke code, and no rebuilt Kubernetes. Deliver ~/research/nats-home-alerting.md: 1) what the article's design is and which parts transfer to a home fleet; 2) two or three concrete shapes for NATS here (for example NATS only as the alert bus with ntfy kept for the phone, JetStream for durable alerts, leaf nodes per host), each with components, where it runs, the NixOS module to use (check services.nats in nixpkgs and its real options), failure behaviour when a host or the cluster is down, security (auth, TLS, the tailnet), and operating cost; 3) how the phone gets the page in each shape, since NATS has no phone app; 4) limitations and unknowns, clearly separated into verified (with file paths or URLs) and inferred; 5) an honest comparison with simply keeping Alertmanager to ntfy, including the case for doing nothing; 6) a recommendation and the smallest reversible experiment that would test it. Keep it short and concrete, lead with the conclusion, no em dashes. When the document is ready, summarize it in a few lines and wait for the owner's questions.";
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
