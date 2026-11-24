# The execution pool's queue (pkgs/exec-pool, docs/records/execution-pool-contract.md) on this host: its own database
# and role in the host's PostgreSQL (postgresql.nix), reached by peer over the socket alone; the schema is the CLI's `migrate` at start,
# its metrics a minutely textfile and its backup a nightly dump. No runner and no slot: nothing claims a task yet.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pkg = pkgs.callPackage ../../pkgs/exec-pool/package.nix { };
  queue = lib.getExe pkg;
  postgres = config.services.postgresql.package;
  # peer: the role is the unit's user
  conninfo = "host=/run/postgresql dbname=exec_pool user=exec_pool";
  dir = "/var/lib/exec-pool-metrics";
  # stdout whatever the exit code (exec_pool_queue_up 0 on a failure), and the unit fails with the CLI
  metrics = pkgs.writeShellApplication {
    name = "exec-pool-metrics";
    text = ''
      rc=0
      ${queue} metrics > ${dir}/exec-pool.prom.tmp || rc=$?
      mv ${dir}/exec-pool.prom.tmp ${dir}/exec-pool.prom
      exit "$rc"
    '';
  };
  unit = {
    after = [ "postgresql.target" ];
    environment.EXEC_POOL_DB = conninfo;
    serviceConfig = {
      Type = "oneshot";
      User = "exec_pool";
      Group = "exec_pool";
      MemoryMax = "32M";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateNetwork = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      NoNewPrivileges = true;
    };
  };
in
{
  imports = [
    ./postgresql.nix
    ./monitoring/node-exporter.nix
    ./backup-metrics.nix
  ];

  users.users.exec_pool = {
    isSystemUser = true;
    group = "exec_pool";
  };
  users.groups.exec_pool = { };
  environment.systemPackages = [ pkg ];

  services.postgresql = {
    ensureDatabases = [ "exec_pool" ];
    ensureUsers = [
      {
        name = "exec_pool";
        ensureDBOwnership = true;
      }
    ];
  };

  systemd.services.exec-pool-migrate = lib.recursiveUpdate unit {
    description = "Apply the execution pool queue's schema";
    # the target: postgresql.service is up before its ensureUsers setup has run
    requires = [ "postgresql.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      RemainAfterExit = true;
      ExecStart = "${queue} migrate";
      # a held lock would otherwise stall the activation that starts it
      TimeoutStartSec = 60;
    };
  };

  services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
  # before the first run: node-exporter counts a missing directory as a textfile scrape error
  systemd.tmpfiles.rules = [ "d ${dir} 0755 exec_pool exec_pool -" ];
  systemd.services.exec-pool-metrics = lib.recursiveUpdate unit {
    description = "Execution pool queue metrics, for node-exporter";
    # exec_pool_slots_declared, beside the busy count the queue knows
    environment.EXEC_POOL_SLOTS = toString config.sam.workers.executionPool.slots;
    # a run before the schema exists would fail; a failed migrate leaves the textfile to go stale
    after = [
      "postgresql.target"
      "exec-pool-migrate.service"
    ];
    requires = [ "exec-pool-migrate.service" ];
    serviceConfig = {
      ExecStart = lib.getExe metrics;
      ReadWritePaths = [ dir ];
      TimeoutStartSec = 30;
    };
  };
  systemd.timers.exec-pool-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "minutely";
  };

  # On-host only, like open-webui's: it guards against a bad write or migration, not a dead disk; lenovo pulls
  # Authentik's dump alone (authentik-offhost.nix).
  homelab.backupMetrics.jobs.exec-pool-backup = "archive_list";
  systemd.services.exec-pool-backup = lib.recursiveUpdate unit {
    description = "Dump the execution pool queue's database";
    requires = [ "postgresql.target" ];
    serviceConfig = {
      StateDirectory = [ "exec-pool-backup" ];
      StateDirectoryMode = "0700";
      UMask = "0077";
      MemoryMax = "64M";
      TimeoutStartSec = 300;
    };
    script = ''
      set -euo pipefail
      dir=/var/lib/exec-pool-backup
      out=$dir/exec-pool-$(date +%Y%m%d-%H%M%S).dump
      ${postgres}/bin/pg_dump -h /run/postgresql -Fc -f "$out.partial" exec_pool
      ${postgres}/bin/pg_restore --list "$out.partial" >/dev/null
      mv "$out.partial" "$out"
      ls -1t "$dir"/exec-pool-*.dump | tail -n +8 | xargs -r rm -f
    '';
  };
  systemd.timers.exec-pool-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:10:00";
      Persistent = true;
    };
  };

  system.checks = [
    (pkgs.runCommand "exec-pool-backup-script-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
      shellcheck --severity=warning ${config.systemd.services.exec-pool-backup.serviceConfig.ExecStart}
      touch $out
    '')
  ];
}
