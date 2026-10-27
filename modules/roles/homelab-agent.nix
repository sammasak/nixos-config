{ config, lib, ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    # kubelet rejects kubernetes.io/node-role labels, so a worker is marked
    # only by lacking the control-plane role: no agent-only k3s settings exist.
    ../homelab/k3s/default.nix
    ../homelab/deploy-target.nix
  ];

  homelab.k3s = {
    enable = true;
    role = "agent";
  };

  # No WWAN hardware on any worker, so ModemManager is only D-Bus attack surface
  # and another resident process on an OOM-prone node. NetworkManager pulls it in.
  systemd.services.ModemManager.enable = lib.mkForce false;

  # 0 = retry forever: the default 4 ends in a secret-agent request no headless worker answers.
  networking.networkmanager.settings.connection."connection.autoconnect-retries" =
    lib.mkIf (config.sam.wifi.declarativeHomeProfile or false) 0;

  # A Nix trusted-user is root-equivalent. deploy-rs connects as `deploy` and
  # becomes root locally via sudo, so the login user never needs it.
  nix.settings.trusted-users = lib.mkForce [ "root" ];
}
