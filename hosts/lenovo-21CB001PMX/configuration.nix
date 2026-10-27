{ config, lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-SAMSUNG_MZVL2512HCJQ-00BL7_S64KNX1T235655")

    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Default boot mode.
    ../../modules/specialisations/desktop.nix

    # Wake msi (the intermittent LLM worker) on the work-hours schedule.
    ../../modules/homelab/msi-power-schedule.nix
  ] ++ lib.optional vars.nativeOtel ../../modules/homelab/native-otel-relay.nix;

  sam.profile = vars;
  sam.hostSecrets.enable = true;

  # acer is reached by LAN address: the tasks run ssh with -F none, so a ~/.ssh/config alias would not resolve
  sam.coordinator.identityFile = "/home/lukas/.ssh/id_coordinator";
  sam.coordinator.fleet = {
    hosts = [ { name = "lenovo"; } { name = "acer-swift"; ssh = "lukas@192.168.10.110"; } ];
    repos = [
      { name = "skills"; gh = "sammasak/skills"; }
      { name = "nixos-config"; gh = "sammasak/nixos-config"; }
      { name = "homelab-gitops"; gh = "sammasak/homelab-gitops"; }
    ];
  };

  # As the always-on control plane, lenovo sends msi its Mon-Fri 09:00 wake.
  homelab.msiPowerSchedule.waker.enable = true;

  # facter.json is gitignored (DMI/MAC data) and generated on-host via
  # nixos-facter; mkIf keeps reportPath at its null default so a checkout
  # without one doesn't hit its readFile on a missing file.
  hardware.facter.reportPath = lib.mkIf (builtins.pathExists ./facter.json) ./facter.json;

  # Declared here, not in the shared sam.hostSecrets tree, so acer never
  # decrypts the private signing key — it only needs the public half already
  # in nix.settings.trusted-public-keys.
  sops.secrets."nix_signing_key" = {
    sopsFile = ../../secrets/homelab/nix-signing-key.yaml;
    owner = "root";
    mode = "0400";
  };

  sops.secrets."native_otlp_auth" = lib.mkIf vars.nativeOtel {
    sopsFile = ../../secrets/claude/native-otlp-auth.yaml;
    key = "token";
    owner = vars.username;
    mode = "0400";
  };

  # Signs deploy-rs closures pushed to acer, whose trusted-users = [ "root" ]
  # would otherwise reject anything copied in over SSH as lukas.
  nix.settings.secret-key-files = [ config.sops.secrets."nix_signing_key".path ];

  # Rebuilds here are manual and precede the push other hosts auto-upgrade from.
  system.autoUpgrade.enable = lib.mkForce false;

  # pi-harness PICODE_EP and factum FACTS_OLLAMA_EP default to localhost:8080. The
  # llm-gateway serves keyless Ollama only on its pod loopback, so only this reaches it.
  systemd.user.services.ollama-portforward = {
    description = "Port-forward the llm-gateway keyless Ollama passthrough to localhost:8080";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionUser = vars.username;
    environment.KUBECONFIG = "%h/.kube/config";
    serviceConfig = {
      ExecStart = "${pkgs.kubectl}/bin/kubectl port-forward --address 127.0.0.1 deploy/llm-gateway -n llm 8080:11434";
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

  # Drops bundled flannel, kube-proxy and the network-policy controller so
  # Cilium's eBPF datapath takes over.
  homelab.k3s.cni = "cilium";

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
      { domain = "*.sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "sammasak.dev"; answer = "192.168.10.203"; }
      { domain = "dns.sammasak.dev"; answer = "192.168.10.154"; }  # AdGuard Home on host
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
    baseUrl = "http://192.168.10.154:2586";
  };

  homelab.clusterWatchdog.enable = true;

  # Grants non-interactive control-plane deploy — a deliberate trust choice.
  # See vault: homelab/decisions/ADR-024-nixos-rebuild-trigger-security-model.md
  homelab.nixosRebuildTrigger.enable = true;
}
