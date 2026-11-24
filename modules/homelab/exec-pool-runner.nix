# The pool runner (#652, pkgs/exec-pool/src/runner_main.rs), homelab.execPool's `runner` role: one
# exec-pool-runner-<slot> per slot, claiming tasks for no agent or one of the slots' agents. It runs as the queue's peer
# role, or with `queueListener` as exec_pool_runner on another host's, and holds no host privilege; on a host with a power
# window it claims only ahead of its drain, which stops the running attempt before the poweroff. The polkit rule
# below lets it start only its slot's exec-pool-exec@ (root, which runs the task in the guest as its user and holds no
# queue access) and dev-env-reset@, which releases the slot with every one of its refusals intact, and clear a refused
# reset's failed state: the slot is quarantined in the queue instead, and the host not left degraded.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.execPool;
  dev = config.services.devEnvironments;
  guestHome = config.users.users.${dev.user}.home or "/home/${dev.user}";
  # every slot is declared alike, so the first one's guest stands for all
  guest = lib.optionalAttrs (cfg.slots > 0) config.containers.pool1.config;
  # what a login shell in the slot would hold: the egress routes' variables, and a PATH with the user's profile, where
  # the agent is; a step does not run under one
  routeVars = lib.concatMap (e: lib.attrNames e.guest.env) (lib.attrValues dev.egress);
  agentEnv = lib.filterAttrs (k: _: lib.elem k routeVars) (guest.environment.variables or { }) // {
    PATH = "/run/wrappers/bin:/etc/profiles/per-user/${dev.user}/bin:/run/current-system/sw/bin";
  };
  pkg = pkgs.callPackage ../../pkgs/exec-pool/package.nix { };
  exe = "${pkg}/bin/exec-pool-runner";
  slotNames = map (n: "pool${toString n}") (lib.range 1 cfg.slots);
  execDir = "/var/lib/exec-pool-exec";
  # the helper stops the task at timeoutSecs; above it, four prepare steps of up to 300 s, the branch listed before and
  # after the run (60 s each) and the stop's own wait; a session turn adds its restore, relink and probes, and the park's
  # push, tried for up to 30 minutes
  execTimeout = cfg.timeoutSecs + 3600;
  # the runner renews it every 10 s while the helper runs, so a run may outlast it; a runner that dies sends its
  # running attempt to review this long after its last renewal
  leaseSecs = 300;
  # this long before a poweroff the runner stops the running attempt (a session's turn parks and pushes its work, a
  # one-shot run goes back to the queue): the step's 60 s stop, the park's push and the reset
  inherit (cfg) drainSecs;
  # a claim no longer has to finish before the poweroff, only to start its run ahead of the drain
  claimSecs = drainSecs + 300;
  slot =
    n:
    builtins.toJSON {
      schema_version = 1;
      host = config.networking.hostName;
      id = n;
      state = "idle";
      inherit (cfg) capabilities;
      agents = [ "none" ] ++ cfg.agents;
    };
  # a queue on another host, by scram over its sam.fleet listener; null: this host's own, by peer
  remote = cfg.queueListener != null;
  listener = config.sam.fleet.listeners.${cfg.queueListener};
  db =
    if remote then
      "host=${
        config.sam.fleet.hosts.${listener.host}.address
      } port=${toString listener.port} dbname=exec_pool user=exec_pool_runner"
    else
      "host=/run/postgresql dbname=exec_pool user=exec_pool";
  # power-schedule.nix's poweroff: the drain stops a run before it fires
  offTimer = "${lib.head (lib.splitString "-" config.networking.hostName)}-scheduled-shutdown.timer";
  powersOff = config.systemd.timers ? ${lib.removeSuffix ".timer" offTimer};
  units = lib.concatMap (n: [
    "exec-pool-exec@${n}.service"
    "dev-env-reset@${n}.service"
  ]) slotNames;
  resets = map (n: "dev-env-reset@${n}.service") slotNames;
  # the deploy's drain (the Justfile's deploy recipe): `on [SECS]` (root) writes the request every runner reads beside
  # its runtime directory (pkgs/exec-pool/src/runner.rs, DRAIN_REQUEST), held until `off` or SECS pass; `wait SECS`
  # returns once no slot's helper runs, 1 at the bound. Its first wait covers a claim taken just before the request,
  # whose helper starts and sees it within one heartbeat.
  drain = pkgs.writeShellApplication {
    name = "exec-pool-drain";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      marker=/run/exec-pool-runner/drain
      busy() { systemctl list-units --no-legend --plain --state=active,activating,deactivating 'exec-pool-exec@*'; }
      case "''${1:-}" in
        on)
          umask 022
          mkdir -p "''${marker%/*}"
          echo "$(($(date +%s) + ''${2:-7200}))" >"$marker.tmp"
          mv "$marker.tmp" "$marker"
          ;;
        off) rm -f "$marker" ;;
        wait)
          end=$((SECONDS + ''${2:-900}))
          sleep 15
          while [ -n "$(busy)" ]; do
            if [ "$SECONDS" -ge "$end" ]; then
              echo "exec-pool-drain: still running:" >&2
              busy >&2
              exit 1
            fi
            sleep 5
          done
          ;;
        *)
          echo "usage: exec-pool-drain on [SECS] | off | wait [SECS]" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{

  imports = [ ./exec-pool-options.nix ];

  config = lib.mkIf (cfg.enable && lib.elem "runner" cfg.roles) {
    environment.systemPackages = [ drain ];

    systemd.services = {
      "exec-pool-exec@" = {
        description = "Run the execution pool attempt handed to slot %i";
        # a restart mid-run would run the attempt again; the run directory refuses that too
        restartIfChanged = false;
        # once per task turn: under systemd's default limit a burst of fast-failing attempts would fail the unit
        startLimitIntervalSec = 0;
        path = [ config.systemd.package ];
        environment = {
          EXEC_POOL_RUNTIME = "/run/exec-pool-runner/%i";
          EXEC_POOL_EXEC_DIR = execDir;
          EXEC_POOL_TIMEOUT_SECS = toString cfg.timeoutSecs;
          EXEC_POOL_GUEST_USER = config.services.devEnvironments.user;
          EXEC_POOL_GIT = lib.getExe pkgs.git;
          EXEC_POOL_ENV = "${pkgs.coreutils}/bin/env";
          EXEC_POOL_MKDIR = "${pkgs.coreutils}/bin/mkdir";
          EXEC_POOL_CP = "${pkgs.coreutils}/bin/cp";
          EXEC_POOL_FIND = "${pkgs.findutils}/bin/find";
          EXEC_POOL_INSTALL = "${pkgs.coreutils}/bin/install";
          EXEC_POOL_CAT = "${pkgs.coreutils}/bin/cat";
          # each slot's dock, which the guest sees at /session (pkgs/exec-pool/src/workspace.rs)
          EXEC_POOL_SESSIONS = "${dev.stateDir}/.sessions";
          EXEC_POOL_GUEST_HOME = guestHome;
          # the host side of the guest home, whose identity admits an attempt only after a reset
          EXEC_POOL_SLOT_HOME = "${dev.stateDir}/%i/home";
          EXEC_POOL_AGENT_ENV = builtins.toJSON agentEnv;
          # the attempt's commits, in its checkout's own config: the agent runs with the workspace's HOME
          EXEC_POOL_GIT_NAME = config.sam.userConfig.git.userName;
          EXEC_POOL_GIT_EMAIL = config.sam.userConfig.git.email;
          # node-exporter's (monitoring/node-exporter.nix): the failed prepares' and park pushes' counts, one file per slot
          EXEC_POOL_TEXTFILE = "/run/node-exporter-textfile";
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
            EXEC_POOL_DRAIN_SECS = toString drainSecs;
          };
          serviceConfig = {
            ExecStart = "${exe} run";
            User = "exec_pool";
            Group = "exec_pool";
            Restart = "always";
            RestartSec = 30;
            RuntimeDirectory = "exec-pool-runner/${n}";
            # the manifest and the cancel marker of a run its helper still runs: a restarted runner takes it over
            RuntimeDirectoryPreserve = "yes";
            StateDirectory = "exec-pool-runner";
            # a session's transcript (up to 32 MiB, pkgs/exec-pool/src/queue.rs) passes through it at a claim and a park
            MemoryMax = "256M";
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
        assertion =
          !remote
          || (
            config.sam.fleet.listeners ? ${cfg.queueListener}
            && listener.host != config.networking.hostName
            && lib.elem config.networking.hostName listener.from
          );
        message = "homelab.execPool.queueListener: ${toString cfg.queueListener} must be a sam.fleet listener on another host whose `from` names ${config.networking.hostName}.";
      }
    ];
  };
}
