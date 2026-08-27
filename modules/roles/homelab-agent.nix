# Homelab k3s agent role
# Use this role for worker nodes
{ lib, ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/agent.nix
    ../homelab/tailscale.nix
  ];

  # Agent role defaults
  homelab.k3s = {
    enable = true;
    role = "agent";
  };

  # Every worker joins the tailnet directly, as a plain client.
  #
  # DECISION (owner, 2026-08-26): NO direct tailscale client on workers.
  # Remote access rides the control-plane subnet router (phone -> tailnet ->
  # lenovo -> LAN). The only scenario a direct client would serve is
  # "lenovo dead while owner is remote" — and the lenovo-death runbook
  # (vault: homelab/runbooks/lenovo-death-recovery.md) shows that scenario
  # requires physical recovery anyway; a shell on an unorchestratable worker
  # remediates nothing. Client-mode machinery remains in
  # modules/homelab/tailscale.nix if this is ever revisited.

  # No WWAN/modem hardware on any worker — ModemManager is pure D-Bus attack
  # surface and one more resident process on an OOM-prone node.
  # NetworkManager pulls it in by default; force it off.
  systemd.services.ModemManager.enable = lib.mkForce false;

  # A Nix trusted-user is root-equivalent (it can inject arbitrary store paths
  # and override substituters). Deploys are push-from-lenovo over SSH as root,
  # so the login user never needs it. Workers only: lenovo keeps root + lukas
  # from modules/core/users.nix because it builds locally.
  nix.settings.trusted-users = lib.mkForce [ "root" ];
}
