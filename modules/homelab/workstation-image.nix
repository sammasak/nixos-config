# Workstation image profile for KubeVirt VMs.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.workstation;
in
{
  options.homelab.workstation = {
    enable = lib.mkEnableOption "headless workstation image profile";
  };

  config = lib.mkIf cfg.enable {
    # Cloud-init data is passed from KubeVirt Secret volumes.
    services.cloud-init.enable = true;

    # Better guest behavior on virtualization hosts.
    services.qemuGuest.enable = true;

    # Align boot settings with image generator defaults for virtual disks.
    boot.loader.timeout = lib.mkForce 0;
    boot.loader.grub.device = lib.mkForce "/dev/vda";
    boot.loader.grub.efiSupport = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    # Trim desktop-oriented services inherited from base role for VM images.
    services.libinput.enable = lib.mkForce false;
    services.blueman.enable = lib.mkForce false;
    services.tumbler.enable = lib.mkForce false;
    services.pipewire.enable = lib.mkForce false;
    security.rtkit.enable = lib.mkForce false;

    # Keep VM always available for task execution.
    services.logind.settings.Login = {
      HandleLidSwitch = lib.mkForce "ignore";
      HandleLidSwitchExternalPower = lib.mkForce "ignore";
      HandleLidSwitchDocked = lib.mkForce "ignore";
      IdleAction = lib.mkForce "ignore";
      HandlePowerKey = lib.mkForce "poweroff";
    };

    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };

    environment.systemPackages = with pkgs; [
      # VCS
      git
      git-lfs

      # Shell and core utilities
      bash          # explicit bash (SHELL env on claude-worker points here; avoids $RANDOM / bash-ism issues)
      openssh
      rsync
      tmux
      coreutils
      util-linux    # provides uuidgen (safe unique suffix generation instead of $RANDOM)
      file          # file type detection
      tree
      socat         # TCP debugging and port-forward scripting (also covers netcat use cases)

      # Data and search tools
      jq
      yq-go
      ripgrep
      fd

      # Build / task runner
      just

      # Kubernetes / GitOps
      kubectl
      kubernetes-helm  # helm chart management
      fluxcd

      # Nix tooling
      direnv
      nix-direnv
      nixfmt-rfc-style  # format .nix files in-place

      # TLS / crypto
      openssl

      # Network
      curl
      wget
      dnsutils     # dig, nslookup for DNS debugging

      # Secrets
      sops
      age

      # Containers
      buildah      # rootless container builds
      skopeo       # inspect / copy / tag OCI images without a daemon
      shadow       # provides newuidmap/newgidmap for user namespaces

      # Code quality / linting (global — no nix develop needed for CI-style checks)
      shellcheck   # shell script linting
      hadolint     # Dockerfile linting
      yamllint     # YAML linting (complements yq-based validate-manifest hook)
    ];
  };
}
