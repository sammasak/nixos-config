{ lib, ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix

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

  # A Nix trusted-user is root-equivalent. Deploys are push-from-lenovo over SSH
  # as root, so the login user never needs it.
  nix.settings.trusted-users = lib.mkForce [ "root" ];
}
