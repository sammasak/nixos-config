{ lib, pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    (import ../../modules/hardware/disko-single-ext4.nix "/dev/disk/by-id/nvme-INTEL_SSDPEKNW010T8_BTNH014425J11P0B")

    ../../modules/hardware/video/${vars.videoDriver}.nix
    # the agent-runtime templates acer admits; their host policy is below
    ../../modules/agent-runtime/templates/rust-pilot.nix
    ../../modules/agent-runtime/templates/claude-coder.nix
    ../../modules/agent-runtime/templates/claude-session.nix
  ];

  # The supervised agent-runtime pilot (#165/#169): one instance of one template at a time, admitted
  # only while acer keeps 4 GiB free beyond the 3 GiB cap, sized from k3s's measured peak. The sizing,
  # deploy, run and rollback are in docs/agent-runtime-pilot.md and docs/agent-runtime-coder.md.
  sam.agentRuntime.host = {
    enable = true;
    eligibleTemplates = [ "rust-pilot" "claude-coder" "claude-session" ];
    maxConcurrentInstances = 1;
    reserve = { memoryMiB = 4096; diskMiB = 51200; };
  };

  # The coder template's only egress in a live run is the Claude API host; #137 pins the allowlist to
  # the resolved IPs (TLS 443). No wildcard, no extra host. The run itself is owner-gated
  # (docs/agent-runtime-coder.md); the template still grants no GitHub capability.
  sam.agentRuntime.templates.claude-coder.network.allow = [ "api.anthropic.com" ];

  # The host's own Claude Code as an interactive instance session (docs/agent-runtime-session.md):
  # same single egress host; the Herdr user attaches, and starts and ends sessions through the one
  # sudo-ruled helper, which delivers the subscription token itself.
  sam.agentRuntime.templates.claude-session.network.allow = [ "api.anthropic.com" ];
  sam.agentRuntime.session = {
    attachUser = vars.username;
    credentialFile = "/run/secrets/claude_oauth_token";
    launch.enable = true;
  };

  sam.profile = vars;
  sam.hostSecrets.enable = true;
  # The worker host: Herdr-started workers run in bypassPermissions, trusted in these checkouts and $HOME.
  sam.herdr.worker = {
    enable = true;
    trustedDirs = map (d: "/home/${vars.username}/${d}") [ "claude-code-skills" "nixos-config" ];
  };

  # Headless shell mode remains the default for the always-on worker. The GUI
  # variant is an explicit boot-menu specialisation for daily laptop use.
  specialisation.desktop.configuration = {
    imports = [ ../../modules/specialisations/desktop.nix ];
  };

  # Sole worker — an unattended reboot is a total cluster outage (the reserved
  # taint strands DNS, kyverno and ntfy, so paging dies with it). Upgrades still
  # build and activate; the reboot is operator-initiated.
  system.autoUpgrade.allowReboot = lib.mkForce false;

  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.cni = "cilium";  # match control-plane: disable kube-proxy for Cilium KPR
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Keep turbo available for interactive coding and builds. Power-profiles-daemon
  # still provides the battery-aware system profile; EPP keeps sustained work
  # balanced instead of forcing the server-oriented power bias.
  sam.thermal = {
    enable = true;
    platform = "generic";
    profile = "balanced";
    disableTurboBoost = false;
    energyPerformancePreference = "balance_performance";
  };

  # WiFi powersave lets the NIC enter deep states, causing ~300-500 ms link
  # drops that break k3s API watches.
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
    path = [ pkgs.iputils pkgs.networkmanager pkgs.util-linux ];
    script = ''
      if ! ping -c3 -W2 192.168.10.1 >/dev/null 2>&1; then
        logger -t wifi-selfheal "LAN gateway 192.168.10.1 unreachable — bouncing wlp0s20f3"
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

}
