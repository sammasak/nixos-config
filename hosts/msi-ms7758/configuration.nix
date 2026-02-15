# Host configuration for msi-ms7758
{ ... }:
let
  vars = import ./variables.nix;
in
{
  imports = [
    ./hardware-configuration.nix

    # Hardware
    ../../modules/hardware/video/${vars.videoDriver}.nix

    # Keep GRUB theming consistent with the other machines (Stylix).
    ../../modules/themes/Catppuccin
  ];

  sam.profile = vars;

  # GPU worker: prepare NVIDIA for container workloads.
  #
  # We use CDI (Container Device Interface) generation via the NixOS module.
  # The cluster-side NVIDIA device plugin can then use `cdi-annotations` or
  # `cdi-cri` modes, as long as containerd has CDI enabled.
  hardware.nvidia-container-toolkit.enable = true;

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
    "--node-label=gpu=nvidia"
  ];

  # Enable CDI support in k3s's embedded containerd so GPU devices can be
  # injected using CDI (for example via NVIDIA device plugin `cdi-annotations`).
  #
  # See:
  # - https://docs.k3s.io/advanced#configuring-containerd
  # - https://github.com/cncf-tags/container-device-interface
  services.k3s.containerdConfigTemplate = ''
    {{ template "base" . }}

    [plugins."io.containerd.grpc.v1.cri"]
      enable_cdi = true
      cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
  '';

  # Best-effort ordering: generate CDI spec before k3s starts.
  systemd.services.k3s = {
    wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
    after = [ "nvidia-container-toolkit-cdi-generator.service" ];
  };
}
