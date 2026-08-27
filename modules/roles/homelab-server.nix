{ ... }:
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/k3s/server.nix
    ../homelab/k3s-db-snapshot.nix
    ../homelab/adguardhome.nix
    ../homelab/acme.nix
    ../homelab/tailscale.nix
    ../homelab/ntfy.nix
    ../homelab/cluster-watchdog.nix
    ../homelab/nixos-rebuild-trigger.nix
  ];

  homelab.k3s = {
    enable = true;
    role = "server";
  };

  homelab.tailscale.enable = true;

  # Nightly snapshot of the sqlite datastore that holds all cluster state.
  homelab.k3sDbSnapshot.enable = true;

  # Self-reboot on a hang: no BMC, no remote power path, so the alternative is
  # walking to the machine. Timeouts are generous on purpose, and not set on the
  # agent role because acer-swift is the sole worker.
  # See vault: homelab/postmortems/2026-08-26-acer-swift-hang-during-lean-pass.md
  # Canonical names — systemd.watchdog.runtimeTime / .rebootTime are
  # mkRenamedOptionModule aliases that warn on every evaluation.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "2min";
    RebootWatchdogSec = "5min";
  };
}
