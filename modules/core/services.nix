{ config, lib, ... }:
let
  username = config.sam.profile.username;
  hasDesktop = config.sam.desktop.enable;
in
{
  services = lib.mkMerge [
    {
    fstrim.enable = true;

    openssh = {
      enable = true;
      ports = [ 22 ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        AllowUsers = [ username ];
        UseDns = false;
        X11Forwarding = false;
        PermitRootLogin = "no";
        PubkeyAuthentication = true;
      };
    };

    }
    (lib.mkIf hasDesktop {
    libinput.enable = true;
    devmon.enable = true;
    gvfs.enable = true;
    udisks2.enable = true;

    blueman.enable = true;
    tumbler.enable = true;

    pulseaudio.enable = false;
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
      extraConfig.pipewire."92-low-latency" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.quantum" = 256;
          "default.clock.min-quantum" = 256;
          "default.clock.max-quantum" = 256;
        };
      };
    };
    })
  ];

  security.rtkit.enable = lib.mkDefault hasDesktop;

  # github.com's published ed25519 key (as in modules/homelab/flux.nix): non-interactive
  # ssh clones (pi-ticket's managed clones, no TTY) must not stop at a host-key prompt.
  programs.ssh.knownHosts.github = {
    hostNames = [ "github.com" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
  };

  # ssh_config Include-s this snippet straight from the store, and OpenSSH
  # rejects included files not owned by root or the user. Inside sandboxed
  # sessions (Claude Code's bubblewrap) the store owner maps to nobody, so every
  # ssh, git-over-ssh and deploy-rs call fails. Its unix/vsock/.host targets are unused.
  programs.ssh.systemd-ssh-proxy.enable = false;
}
