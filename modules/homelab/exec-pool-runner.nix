# The pool runner (#652, pkgs/exec-pool/src/runner_main.rs): one exec-pool-runner-<slot> per sam.workers.executionPool
# slot, claiming tasks for no agent or one of the slot's sam.workers.executionPool agents. It runs as the queue's peer
# role, or with `queue` as exec_pool_runner on another host's, and holds no host privilege; on a host with a power
# window it claims only what can finish before the poweroff. The polkit rule below lets it start only its
# slot's exec-pool-exec@ (root, which runs the task in the guest as its user and holds no queue access) and
# dev-env-reset@, which releases the slot with every one of its refusals intact, and clear a refused reset's failed
# state: the slot is quarantined in the queue instead, and the host not left degraded.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.execPool.runner;
  pool = config.sam.workers.executionPool;
  dev = config.services.devEnvironments;
  guestHome = config.users.users.${dev.user}.home or "/home/${dev.user}";
  # every slot is declared alike, so the first one's guest stands for all
  guest = lib.optionalAttrs (pool.slots > 0) config.containers.pool1.config;
  # what a login shell in the slot would hold: the egress routes' variables, and a PATH with the user's profile, where
  # the agent is; a step does not run under one
  routeVars = lib.concatMap (e: lib.attrNames e.guest.env) (lib.attrValues dev.egress);
  agentEnv = lib.filterAttrs (k: _: lib.elem k routeVars) (guest.environment.variables or { }) // {
    PATH = "/run/wrappers/bin:/etc/profiles/per-user/${dev.user}/bin:/run/current-system/sw/bin";
  };
  pkg = pkgs.callPackage ../../pkgs/exec-pool/package.nix { };
  exe = "${pkg}/bin/exec-pool-runner";
  slotNames = map (n: "pool${toString n}") (lib.range 1 pool.slots);
  execDir = "/var/lib/exec-pool-exec";
  # the helper stops the task at timeoutSecs; above it, the two prepare steps and the stop's own wait
  execTimeout = cfg.timeoutSecs + 900;
  # the runner renews it every 10 s while the helper runs, so a run may outlast it; a runner that dies sends its
  # running attempt to review this long after its last renewal
  leaseSecs = 300;
  # the longest a claim holds the slot: the helper's bound, then the settle and the reset; none may outlast a poweroff
  claimSecs = execTimeout + 300;
  slot =
    n:
    builtins.toJSON {
      schema_version = 1;
      host = config.networking.hostName;
      id = n;
      state = "idle";
      inherit (cfg) capabilities;
      agents = [ "none" ] ++ pool.agents;
    };
  # a queue on another host, by scram over its sam.fleet listener; null: this host's own, by peer
  remote = cfg.queue != null;
  listener = config.sam.fleet.listeners.${cfg.queue};
  db =
    if remote then
      "host=${
        config.sam.fleet.hosts.${listener.host}.address
      } port=${toString listener.port} dbname=exec_pool user=exec_pool_runner"
    else
      "host=/run/postgresql dbname=exec_pool user=exec_pool";
  # power-schedule.nix's poweroff: a claim's lease must end before it fires
  offTimer = "${lib.head (lib.splitString "-" config.networking.hostName)}-scheduled-shutdown.timer";
  powersOff = config.systemd.timers ? ${lib.removeSuffix ".timer" offTimer};
  units = lib.concatMap (n: [
    "exec-pool-exec@${n}.service"
    "dev-env-reset@${n}.service"
  ]) slotNames;
  resets = map (n: "dev-env-reset@${n}.service") slotNames;
in
{
  options.homelab.execPool.runner = {
    enable = lib.mkEnableOption "the execution pool's runner, one per sam.workers.executionPool slot";
    timeoutSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "How long a task's command may run in its slot before it is stopped and its attempt goes to needs_review.";
    };
    queue = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "exec-pool-db";
      description = "The sam.fleet listener of the queue's PostgreSQL on another host, reached as exec_pool_runner with the sops password; null: this host's own queue (exec-pool.nix), by peer.";
    };
    capabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "The capabilities each slot offers; a task claims a slot only when it offers every one the task names.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      "exec-pool-exec@" = {
        description = "Run the execution pool attempt handed to slot %i";
        # a restart mid-run would run the attempt again; the run directory refuses that too
        restartIfChanged = false;
        path = [ config.systemd.package ];
        environment = {
          EXEC_POOL_RUNTIME = "/run/exec-pool-runner/%i";
          EXEC_POOL_EXEC_DIR = execDir;
          EXEC_POOL_TIMEOUT_SECS = toString cfg.timeoutSecs;
          EXEC_POOL_GUEST_USER = config.services.devEnvironments.user;
          EXEC_POOL_GIT = lib.getExe pkgs.git;
          EXEC_POOL_ENV = "${pkgs.coreutils}/bin/env";
          EXEC_POOL_MKDIR = "${pkgs.coreutils}/bin/mkdir";
          EXEC_POOL_GUEST_HOME = guestHome;
          # the host side of the guest home, whose identity admits an attempt only after a reset
          EXEC_POOL_SLOT_HOME = "${dev.stateDir}/%i/home";
          EXEC_POOL_AGENT_ENV = builtins.toJSON agentEnv;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${exe} exec %i";
          StateDirectory = "exec-pool-exec";
          StateDirectoryMode = "0755";
          TimeoutStartSec = execTimeout;
        };
      };
    }
    // lib.listToAttrs (
      map (
        n:
        lib.nameValuePair "exec-pool-runner-${n}" {
          description = "Execution pool runner for slot ${n}";
          wantedBy = [ "multi-user.target" ];
          wants = [ "container@${n}.service" ] ++ lib.optional remote "network-online.target";
          requires = lib.optional (!remote) "exec-pool-migrate.service";
          after = [
            "container@${n}.service"
          ]
          ++ (
            if remote then
              [ "network-online.target" ]
            else
              [
                "postgresql.target"
                "exec-pool-migrate.service"
              ]
          );
          path = [ config.systemd.package ];
          environment = {
            EXEC_POOL_DB = db;
            EXEC_POOL_SLOT = slot n;
            EXEC_POOL_LEASE_SECS = toString leaseSecs;
            EXEC_POOL_RUNTIME = "/run/exec-pool-runner/${n}";
            EXEC_POOL_EXEC_DIR = execDir;
            EXEC_POOL_STATE = "/var/lib/exec-pool-runner";
          }
          // lib.optionalAttrs powersOff {
            EXEC_POOL_OFF_TIMER = offTimer;
            EXEC_POOL_CLAIM_SECS = toString claimSecs;
          };
          serviceConfig = {
            ExecStart = "${exe} run";
            User = "exec_pool";
            Group = "exec_pool";
            Restart = "always";
            RestartSec = 30;
            RuntimeDirectory = "exec-pool-runner/${n}";
            StateDirectory = "exec-pool-runner";
            MemoryMax = "64M";
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateNetwork = !remote;
            RestrictAddressFamilies = [ "AF_UNIX" ] ++ lib.optional remote "AF_INET";
            NoNewPrivileges = true;
          }
          // lib.optionalAttrs remote {
            LoadCredential = [ "db-password:${config.sops.secrets.exec_pool_runner_password.path}" ];
          };
        }
      ) slotNames
    );

    users.users.exec_pool = lib.mkIf remote {
      isSystemUser = true;
      group = "exec_pool";
    };
    users.groups.exec_pool = lib.mkIf remote { };
    sops.secrets.exec_pool_runner_password = lib.mkIf remote {
      sopsFile = ../../secrets/homelab/exec-pool-runner.yaml;
      # no restartUnits: a runner restarted mid-run sends its attempt to review; a rotation waits for an idle restart
      mode = "0400";
    };

    # a run's output stays on the host for review; nothing else reads it once its attempt is settled
    systemd.tmpfiles.rules = [ "e ${execDir} - - - 30d" ];

    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        var units = ${builtins.toJSON units};
        var resets = ${builtins.toJSON resets};
        if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "exec_pool" &&
            ((action.lookup("verb") == "start" && units.indexOf(action.lookup("unit")) >= 0) ||
             (action.lookup("verb") == "reset-failed" && resets.indexOf(action.lookup("unit")) >= 0))) {
          return polkit.Result.YES;
        }
      });
    '';

    assertions = [
      {
        assertion = pool.enable && pool.slots > 0;
        message = "homelab.execPool.runner: a runner needs sam.workers.executionPool enabled with a slot.";
      }
      {
        assertion =
          !remote
          || (
            config.sam.fleet.listeners ? ${cfg.queue}
            && listener.host != config.networking.hostName
            && lib.elem config.networking.hostName listener.from
          );
        message = "homelab.execPool.runner.queue: ${toString cfg.queue} must be a sam.fleet listener on another host whose `from` names ${config.networking.hostName}.";
      }
    ];
  };
}
