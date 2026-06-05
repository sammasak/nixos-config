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

  # Disable WiFi power management to prevent brief link flaps.
  # iwlwifi power_save + NetworkManager defaults allow the NIC to enter deep
  # power states, causing ~300-500 ms drops that break k3s virt-handler API
  # watches ("no route to host" on 10.43.0.1:443, clean Exit Code 0).
  # acer-swift sees ~3.3 virt-handler restarts/day vs msi-ms7758's ~0.16/day,
  # consistent with a laptop-specific WiFi instability (msi-ms7758 is wired).
  # See: TICKET-2026-06-06-infra-043.
  networking.networkmanager.wifi.powersave = false;
  boot.extraModprobeConfig = ''
    options iwlwifi power_save=0 d0i3_disable=1
  '';

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
}
