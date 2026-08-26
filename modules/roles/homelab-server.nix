# Homelab k3s server role
# Use this role for control plane nodes
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

  # Server role defaults
  homelab.k3s = {
    enable = true;
    role = "server";
  };

  # Tailscale subnet router for control plane node
  homelab.tailscale.enable = true;

  # Nightly snapshot of the sqlite datastore that holds all cluster state.
  homelab.k3sDbSnapshot.enable = true;

  # Hardware watchdog.
  #
  # The control plane is a laptop with no BMC and no remote power path — the
  # msi-ms7758 decommission established that once a box in this rack hangs, the
  # only recovery is walking to it. Arming the watchdog lets a hung kernel or a
  # wedged control plane reboot itself instead of waiting for a human to reach
  # the power button.
  #
  # Timeouts are deliberately generous: systemd must fail to pet the watchdog
  # for 2 min before the hardware resets, and a reboot gets 5 min to finish
  # before it is forced. Both are far longer than any legitimate stall here, so
  # a spurious reset is unlikely.
  #
  # NOT set on the homelab-agent role yet: acer-swift is the sole worker and an
  # unexpected reset there is a total cluster outage. Observe this on the
  # control plane first.
  #
  # These are the canonical option names. `systemd.watchdog.runtimeTime` /
  # `.rebootTime` still work but are `mkRenamedOptionModule` aliases and emit a
  # deprecation warning on every evaluation.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "2min";
    RebootWatchdogSec = "5min";
  };
}
