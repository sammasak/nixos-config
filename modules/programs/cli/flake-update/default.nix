# Weekly `nix flake update` for the personal nixos-config checkout.
#
# Keeps the lock from rotting between manual rebuilds. It commits locally and
# never pushes: the human still reviews the diff, rebuilds, and pushes.
# This used to be skipped on the workstation/worker VM images, which were
# disposable and rebuilt from a pinned revision with no personal nixos-config
# checkout to keep fresh. Those images were retired with the KubeVirt platform;
# every remaining host is a physical machine, so the timer is unconditional.
# The script still no-ops when ~/nixos-config is not a git checkout.
{ pkgs, ... }:
let
  flakeUpdate = pkgs.writeShellApplication {
    name = "nixos-config-flake-update";
    runtimeInputs = [
      pkgs.git
      pkgs.nix
    ];
    text = ''
      repo="$HOME/nixos-config"

      if [ ! -d "$repo/.git" ]; then
        echo "flake-update: $repo is not a git checkout, nothing to do"
        exit 0
      fi

      # Only ever act on an otherwise-clean tree. Any modified, staged or
      # untracked path other than flake.lock means work is in progress, and an
      # automated commit would sweep it up. Back off entirely instead.
      dirty="$(git -C "$repo" status --porcelain | grep -Ev '^( M|M |MM) flake\.lock$' || true)"
      if [ -n "$dirty" ]; then
        echo "flake-update: working tree is not clean, skipping. Offending paths:"
        echo "$dirty"
        exit 0
      fi

      nix flake update --flake "$repo"

      if git -C "$repo" diff --quiet -- flake.lock; then
        echo "flake-update: lock is already current, nothing to commit"
        exit 0
      fi

      git -C "$repo" add flake.lock
      git -C "$repo" commit -m "chore(flake): weekly lock update"
      echo "flake-update: committed a new flake.lock — review, rebuild, then push"
    '';
  };
in
{
  home.packages = [ flakeUpdate ];

  systemd.user.services.nixos-config-flake-update = {
    Unit = {
      Description = "Weekly flake.lock update for ~/nixos-config";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${flakeUpdate}/bin/nixos-config-flake-update";
    };
  };

  systemd.user.timers.nixos-config-flake-update = {
    Unit = {
      Description = "Weekly flake.lock update for ~/nixos-config";
    };
    Timer = {
      # Sunday morning, after the 03:00 system auto-upgrade window.
      OnCalendar = "Sun 05:00";
      # Laptops are asleep more often than not — run on next boot if missed.
      Persistent = true;
      RandomizedDelaySec = "30m";
      Unit = "nixos-config-flake-update.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
