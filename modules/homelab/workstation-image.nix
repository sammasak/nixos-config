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
      git
      git-lfs
      openssh
      rsync
      tmux
      jq
      ripgrep
      fd
      just
      kubectl
      direnv
      nix-direnv
    ];
  };
}
