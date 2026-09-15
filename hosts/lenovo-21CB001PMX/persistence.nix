# STAGED, NOT IMPORTED: activation needs the physical migration runbook
# (rescue media + /persist disk carve + on-site reboot, plan §5.3 step 5) and
# the impermanence input/module wiring, neither of which exists yet. No
# per-entry `neededForBoot` here: upstream nix-community/impermanence gates
# the whole bucket via `fileSystems."/persist".neededForBoot` instead
# (impermanence-fs.nix), verified against its source this session.
{ ... }:
{
  environment.persistence."/persist" = {
    hideMounts = true;

    directories = [
      "/etc/ssh"
      "/var/lib/sops-nix"
      "/etc/NetworkManager/system-connections"

      { directory = "/home"; user = "lukas"; group = "users"; mode = "0755"; }
      "/var/lib/rancher/k3s"
      "/var/lib/acme"
      # DynamicUser: real content is under /var/lib/private/<name>, not the
      # /var/lib/<name> symlink systemd regenerates every activation.
      "/var/lib/private/ntfy-sh"
      "/var/lib/private/AdGuardHome"
      "/var/lib/k3s-db-snapshots"
      "/var/lib/tailscale"
      "/var/lib/nixos-rebuild-trigger"
      "/var/log/journal"
      "/root/.ssh"
    ];

    files = [
      "/etc/machine-id"
    ];
  };
}
