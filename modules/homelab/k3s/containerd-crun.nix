{ config, pkgs, lib, ... }:

{
  # Install crun binary
  environment.systemPackages = [ pkgs.crun ];

  # Write k3s containerd config template that registers crun as an additional runtime.
  # k3s reads this file at startup instead of generating its own config.toml.
  # We keep 'runc' as the default so existing workloads are unaffected.
  # Sandbox Jobs select 'crun' explicitly via RuntimeClass.
  systemd.services.k3s-containerd-config = {
    description = "Write k3s containerd runtime config template";
    wantedBy = [ "k3s.service" ];
    before = [ "k3s.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = let
      crunBin = "${pkgs.crun}/bin/crun";
    in ''
      mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
      cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TOML'
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "runc"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun]
  runtime_type = "io.containerd.runc.v2"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.crun.options]
    BinaryName = "${crunBin}"
    SystemdCgroup = true
TOML
    '';
  };
}
