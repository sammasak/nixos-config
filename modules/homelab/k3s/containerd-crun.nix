{ config, pkgs, lib, ... }:

{
  # Install crun and gVisor (runsc) binaries
  environment.systemPackages = [ pkgs.crun pkgs.gvisor ];

  # Symlink containerd-shim-runsc-v1 so k3s's bundled containerd can discover it.
  # Symlink criu into /var/lib/rancher/k3s/data/cni/ which is in k3s's constructed
  # PATH for containerd/shim processes, allowing crun to find criu for checkpointing.
  systemd.tmpfiles.rules = [
    "L+ /usr/local/sbin/containerd-shim-runsc-v1 - - - - ${pkgs.gvisor}/bin/containerd-shim-runsc-v1"
    "L+ /var/lib/rancher/k3s/data/cni/criu - - - - ${pkgs.criu}/bin/criu"
  ];

  # CRIU for container checkpoint/restore (Sprint 2)
  programs.criu.enable = true;

  # Write k3s containerd config template using an activation script so it runs
  # on every nixos-rebuild switch (not just at k3s start). This ensures the
  # template is always up-to-date on disk before k3s next reads it.
  #
  # k3s reads config.toml.tmpl instead of generating its default config.toml.
  # The template uses containerd v3 format (k3s >= 1.32 / containerd >= 2.0).
  # runc remains the default runtime; crun is added for RuntimeClass "crun".
  system.activationScripts.k3s-containerd-crun = {
    text = let
      crunBin = "${pkgs.crun}/bin/crun";
    in ''
      mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
      cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TOML'
version = 3
root = "/var/lib/rancher/k3s/agent/containerd"
state = "/run/k3s/containerd"

[grpc]
  address = "/run/k3s/containerd/containerd.sock"

[plugins.'io.containerd.internal.v1.opt']
  path = "/var/lib/rancher/k3s/agent/containerd"

[plugins.'io.containerd.grpc.v1.cri']
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true
  use_local_image_pull = true

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = "rancher/mirrored-pause:3.6"

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ["/var/lib/rancher/k3s/data/cni"]
  conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.crun]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.crun.options]
  BinaryName = "${crunBin}"
  SystemdCgroup = true

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runhcs-wcow-process]
  runtime_type = "io.containerd.runhcs.v1"

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
TOML
    '';
  };

  # Backwards-compatible no-op service (activation script replaced this).
  systemd.services.k3s-containerd-config = {
    description = "Write k3s containerd runtime config template";
    wantedBy = [ "k3s.service" ];
    before = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      echo "k3s containerd config written by NixOS activation script"
    '';
  };
}
