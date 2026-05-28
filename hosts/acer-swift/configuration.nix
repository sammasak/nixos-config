# Host configuration for acer-swift
{ lib, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Desktop mode (default boot)
    ../../modules/specialisations/desktop.nix

    # Register crun as additional containerd runtime for k3s
    ../../modules/homelab/k3s/containerd-crun.nix
  ];

  sam.profile = vars;
  sam.secrets.enable = true;

  # Server specialisation (boot menu option for headless mode)
  specialisation.server.configuration = {
    imports = [ ../../modules/specialisations/server.nix ];
  };

  # k3s agent configuration
  homelab.k3s.serverAddr = "https://192.168.10.154:6443";  # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];

  # Acer laptop: use generic thermal policy (BIOS/EC fan tables + thermald).
  # Turbo boost disabled: keeps idle package temp ~10-15°C lower (below the 63°C fan trigger).
  # EPP balance_power: biases HWP toward lower voltage/frequency at idle.
  hardware.thermal = {
    enable = true;
    platform = "generic";
    profile = "balanced";
    disableTurboBoost = true;
    energyPerformancePreference = "balance_power";
  };

  # Keep laptop always on - never sleep on lid close (override laptop defaults)
  services.logind.settings.Login = {
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
    HandleLidSwitchDocked = lib.mkForce "ignore";
    IdleAction = lib.mkForce "ignore";
    HandlePowerKey = lib.mkForce "poweroff";
  };

  # Disable sleep/hibernate
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Disable Wi-Fi power-save on the iwlwifi adapter (wlp0s20f3).
  # This node has no wired ethernet, so the k3s agent->server remotedialer
  # tunnel and all pod traffic to kubernetes.default both ride wlp0s20f3.
  # With powersave on (the iwlwifi default), the radio periodically dozes
  # between frames and drops the WebSocket with close code 1006, which
  # causes every leader-elected pod on the node to lose its lease and
  # crash simultaneously. Investigated in TICKET-2026-05-23-infra-002.
  networking.networkmanager.wifi.powersave = false;
}
