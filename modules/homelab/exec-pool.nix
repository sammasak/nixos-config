# The execution pool's queue (pkgs/exec-pool, docs/records/execution-pool-contract.md) on this host: its own database
# and role in the host's PostgreSQL (postgresql.nix), reached by peer over the socket alone; the schema is the CLI's `migrate` at start,
# its metrics a minutely textfile and its backup a nightly dump; the runner, off by default, is exec-pool-runner.nix.
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
    ./exec-pool-runner.nix
    {
      options.homelab.execPool.remoteRunners = lib.mkEnableOption "the exec_pool_runner role for the sam.fleet exec-pool-db listener's hosts, over TCP by scram (postgresql.nix); off, Postgres keeps no TCP listener";
    }
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
  # `exec-pool submit | status | list` for these users; a worker guest's user is added here
  homelab.postgresql.clients.exec_pool_submit = {
    database = "exec_pool";
    users = [ "lukas" ];
  };
  homelab.postgresql.remoteClients = lib.mkIf config.homelab.execPool.remoteRunners {
    exec_pool_runner = {
      database = "exec_pool";
      listener = "exec-pool-db";
    };
  };

  homelab.secrets.enable = lib.mkIf config.homelab.execPool.remoteRunners true;
  sops.secrets.exec_pool_runner_password = lib.mkIf config.homelab.execPool.remoteRunners {
    sopsFile = ../../secrets/homelab/exec-pool-runner.yaml;
    mode = "0400";
    restartUnits = [ "exec-pool-runner-password.service" ];
  };
  # The role's scram verifier from the sops password. psql reads the value from the credential, so it is on no
  # command line, and the session logs no statement: a failed ALTER would otherwise print it in the server log.
  systemd.services.exec-pool-runner-password = lib.mkIf config.homelab.execPool.remoteRunners {
    description = "Set the exec_pool_runner role's password";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ postgres ];
    environment.PGPORT = toString config.services.postgresql.settings.port;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      Group = "postgres";
      LoadCredential = [ "password:${config.sops.secrets.exec_pool_runner_password.path}" ];
      PrivateNetwork = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      NoNewPrivileges = true;
      TimeoutStartSec = 60;
    };
    script = ''
      psql -h /run/postgresql -d postgres -v ON_ERROR_STOP=1 -q <<'EOF'
      SET log_statement = 'none';
      SET log_min_error_statement = 'panic';
      \set pw `cat "$CREDENTIALS_DIRECTORY/password"`
      ALTER ROLE exec_pool_runner WITH LOGIN PASSWORD :'pw';
      EOF
    '';
  };

  systemd.services.exec-pool-migrate = lib.recursiveUpdate unit {
    description = "Apply the execution pool queue's schema";
    # the target: postgresql.service is up before its ensureUsers setup has run. postgresql-setup too: a switch
    # restarts it with no job on the target, and migration 0002 grants to the role it creates.
    after = [
      "postgresql.target"
      "postgresql-setup.service"
    ];
    requires = [
      "postgresql.target"
      "postgresql-setup.service"
    ];
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
