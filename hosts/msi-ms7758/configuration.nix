# Host configuration for msi-ms7758
{ pkgs, ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix
  ];

  sam.profile = vars;

  # Headless GPU worker: prepare NVIDIA for container workloads.
  hardware.nvidia-container-toolkit.enable = true;

  # Ollama backend (kept local by default; expose via SSH tunnel or add firewall
  # rules if you want LAN access).
  services.ollama = {
    enable = true;
    # Kepler + legacy 470xx: CUDA builds are often incompatible; try Vulkan first.
    package = pkgs.ollama-vulkan;
    host = "127.0.0.1";
    openFirewall = false;
  };

  # Shared Windows ESP is only 100 MiB; keep the GRUB menu short.
  boot.loader.grub.configurationLimit = 5;

  # Windows entry for GRUB (works when booted in UEFI mode).
  boot.loader.grub.extraEntries = ''
    menuentry "Windows Boot Manager" {
      insmod part_gpt
      insmod fat
      insmod chain
      search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
      chainloader /EFI/Microsoft/Boot/bootmgfw.efi
    }
  '';

  # Desktop tower: no automatic suspend/hibernate behavior.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandlePowerKey = "poweroff";
  };

  # k3s agent configuration (worker node by default)
  homelab.k3s.serverAddr = "https://192.168.10.154:6443"; # k3s server on lenovo-21CB001PMX
  homelab.k3s.extraFlags = [
    "--node-label=node-pool=workers"
  ];
}
