{ config, lib, ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix
    ../homelab/deploy-target.nix

    # Imported but left disabled: workers run no Tailscale client, so remote
    # access rides the control-plane subnet router.
    ../homelab/tailscale.nix
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
