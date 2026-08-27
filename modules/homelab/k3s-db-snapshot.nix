# Daily snapshot of the k3s datastore (control plane only).
#
# All Kubernetes state lives in one sqlite file, and a corrupt state.db is not
# something Flux can fix: the API server will not start, so nothing reconciles.
# Guards CORRUPTION only — there is deliberately no off-host copy, so a dead
# disk is still a reinstall-and-let-Flux-rebuild event.
# See vault: homelab/runbooks/k3s-datastore-snapshot-restore.md
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.homelab.k3sDbSnapshot;
in
{
  options.homelab.k3sDbSnapshot = {
    enable = mkEnableOption "daily snapshots of the k3s sqlite datastore";

    databasePath = mkOption {
      type = types.str;
      default = "/var/lib/rancher/k3s/server/db/state.db";
      description = "Path to the k3s sqlite datastore.";
    };

    snapshotDir = mkOption {
      type = types.str;
      default = "/var/lib/k3s-db-snapshots";
      description = "Directory the gzipped snapshots are written to (root-only).";
    };

    keep = mkOption {
      type = types.ints.positive;
      default = 7;
      description = "Number of snapshots to retain; older ones are pruned.";
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 03:10:00";
      description = "systemd OnCalendar expression. Default: daily at 03:10.";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.snapshotDir} 0700 root root -"
    ];

    systemd.services.k3s-db-snapshot = {
      description = "Snapshot the k3s sqlite datastore";
      after = [ "k3s.service" ];

      path = [ pkgs.sqlite pkgs.gzip pkgs.coreutils pkgs.findutils ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # A wedged sqlite lock must not leave the unit running until the next
        # timer tick.
        TimeoutStartSec = "10min";
        # Background maintenance: never compete with the API server for IO.
        Nice = 10;
        IOSchedulingClass = "idle";
      };

      script = ''
        db="${cfg.databasePath}"
        dir="${cfg.snapshotDir}"

        # Guard: an etcd-backed or not-yet-bootstrapped server has no sqlite
        # datastore. Say so in the journal and exit clean rather than failing
        # the unit every night.
        if [ ! -f "$db" ]; then
          echo "k3s-db-snapshot: no sqlite datastore at $db — nothing to snapshot, skipping"
          exit 0
        fi

        target="$dir/state-$(date +%Y%m%d).db"
        rm -f "$target" "$target.gz"

        # .backup is the online backup API; .timeout rides out k3s' write locks.
        sqlite3 -cmd ".timeout 30000" "$db" ".backup '$target'"
        gzip -9 -f "$target"
        echo "k3s-db-snapshot: wrote $target.gz ($(stat -c %s "$target.gz") bytes, source $(stat -c %s "$db") bytes)"

        # Retention: keep the newest N, prune the rest.
        find "$dir" -maxdepth 1 -type f -name 'state-*.db.gz' -printf '%T@ %p\n' \
          | sort -rn \
          | tail -n +${toString (cfg.keep + 1)} \
          | cut -d' ' -f2- \
          | while read -r old; do
              echo "k3s-db-snapshot: pruning $old"
              rm -f "$old"
            done
      '';
    };

    systemd.timers.k3s-db-snapshot = {
      description = "Daily k3s sqlite datastore snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };
  };
}
