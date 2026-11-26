# The execution pool's one option set (docs/records/execution-pool-contract.md, Turning it on). Three parts read it:
# the slots (modules/workers/execution-pool.nix, every host), the runner (exec-pool-runner.nix) and the queue
# (exec-pool.nix, which turns on this host's PostgreSQL and so is imported only where the queue runs).
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.homelab.execPool;
  has = r: lib.elem r cfg.roles;
  fleetHost = config.sam.fleet.hosts.${config.networking.hostName} or { };
in
{
  options.homelab.execPool = {
    enable = lib.mkEnableOption "the execution pool on this host: its slots, and the roles it takes";
    roles = mkOption {
      type = types.listOf (
        types.enum [
          "queue"
          "runner"
        ]
      );
      default = [ ];
      example = [
        "queue"
        "runner"
      ];
      description = "What this host does for the pool: `queue` keeps the tasks, sessions and transcripts in its PostgreSQL (import modules/homelab/exec-pool.nix); `runner` claims tasks for its slots, from this host's queue or `queueListener`'s. Neither: slots alone, claimed by nothing.";
    };
    slots = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = "How many slots, named pool1..pool<slots>, each a reusable environment with no agent and no prompt; each reserves `slot.memory` of sam.workers.pool.memory. A slot dropped by a lower count keeps its home: retire it.";
    };
    slot = {
      memory = mkOption {
        type = types.strMatching "[1-9][0-9]*[KMGT]?";
        default = "2G";
        description = "Each slot's MemoryMin, as an instance's memory.reserved.";
      };
      cpu = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Each slot's cores, as an instance's cpu.reserved.";
      };
      privateUsers = mkOption {
        type = types.bool;
        default = false;
        description = "Each slot in its own 65536 uids (the instances' rootInGuest, without its sudo): guest root is an unprivileged host uid, a slot has its own sshd key and nix fetcher cache, and a reset empties that cache. A slot's home made in the other block is replaced by a fresh one at its next start.";
      };
    };
    light = {
      slots = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "How many of `slots`, the last ones, are light: `light.memory` reserved, `light.cpu` cores of CPUWeight and a CPUQuota of `light.cpuQuota`, so on a hot host one adds work without taking the others' share or the idle cores' heat.";
      };
      memory = mkOption {
        type = types.strMatching "[1-9][0-9]*[KMGT]?";
        default = "1G";
        description = "A light slot's MemoryMin.";
      };
      cpu = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "A light slot's cores, as an instance's cpu.reserved.";
      };
      cpuQuota = mkOption {
        type = types.strMatching "[1-9][0-9]*%";
        default = "200%";
        description = "A light slot's CPUQuota: its ceiling even while other cores sit idle.";
      };
    };
    repos = mkOption {
      type = types.listOf types.str;
      # what tasks hand back to, and nixos-config's private flake and devenv inputs for its fetch
      default = map (r: "sammasak/${r}") [
        "nixos-config"
        "skills"
        "alert-bridge"
        "factum"
        "nix-audit"
        "llm-gateway"
        "rf-proto"
        "herman"
        "devenv-platform"
        "paddock"
        "pi-harness"
      ];
      description = "The GitHub repositories a slot reaches, through the host's sidecar (or sam.fleet.listeners.github-egress's host), which signs its fetch, push and gh calls so the slot holds no credential. A session's park pushes its snapshot ref there too. A repository whose flake or devenv has a private input needs that input listed.";
    };
    ownRefsOnly = mkOption {
      type = types.bool;
      default = false;
      description = "A slot pushes only its task's branch `pool/<task id>` and snapshot `refs/pool-wip/<task id>`: the host's exec-pool-push-filter reads each push's ref updates, against the runner's manifest of the slot's attempt, before the sidecar signs it. Off, a slot may push any ref of a listed repository.";
    };
    agents = mkOption {
      type = types.listOf (
        types.enum [
          "claude"
          "codex"
          "pi"
        ]
      );
      default = [ ];
      example = [ "claude" ];
      description = "Agents a task may run in a slot, each through its egress proxy with no credential in the guest (anthropic; openai with sam.workers.codexAuthFile; llm-gateway with the host's Pi key). Sessions run claude only. The CLIs are the workers' guest packages (modules/workers/default.nix).";
    };
    agentMarkers = mkOption {
      type = types.attrsOf types.str;
      default = { };
      internal = true;
      description = "Agents of `agents` a runner offers only while this file exists as it starts; another module restarts the runners when the file comes or goes.";
    };
    capabilities = mkOption {
      type = types.listOf (
        types.enum [
          "github"
          "monitoring"
          "always-on"
        ]
      );
      default = [ ];
      description = "The capabilities each slot offers, set from the host's own facts: `github` with `repos` (fetch, push and gh through the sidecar), `monitoring` with `monitoring`, `always-on` on a host with no power window that never sleeps (sam.fleet.hosts); a host's own definition adds to them. Each slot also always offers `host-<networking.hostName>` (`host-acer-swift`), so `--requires host-acer-swift` places a task on that host. A task claims a slot only when it offers every one the task names (`exec-pool submit --requires NAME`), and submit refuses a task no slot seen in the last day offers them to.";
    };
    timeoutSecs = mkOption {
      type = types.ints.positive;
      default = 1800;
      description = "How long a task's command, or a session's agent since it last idled, wrote its transcript or ran its own background job (four times this since it last idled), may run in its slot before it is stopped: a one-shot attempt then goes to needs_review, a session's turn parks as turn_timeout and continues in a new turn, up to three in a row with no message between.";
    };
    sessionSurface = mkOption {
      type = types.enum [
        "pane"
        "headless"
      ];
      default = "pane";
      description = "Where a session turn's agent runs: interactive Claude in the slot's pane in the host user's Herdr, or headless, Claude's print mode with no pane and no idle pause, its turn ending when the call does.";
    };
    idleGraceSecs = mkOption {
      type = types.ints.unsigned;
      default = 120;
      description = "How long a session's agent, idle and waiting for input, stays in its slot's Herdr pane, where the owner's typing or a message sent to the session answers it in the same turn, before the session parks (its work pushed) and frees the slot.";
    };
    idleGraceBusySecs = mkOption {
      type = types.ints.unsigned;
      default = 60;
      description = "idleGraceSecs while a task is queued and no slot is idle on any host.";
    };
    queueListener = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "exec-pool-db";
      description = "For a runner on a host without the queue: the sam.fleet listener of the queue's PostgreSQL, reached as exec_pool_runner with the sops password. Null: this host's own queue, by peer.";
    };
    remoteRunners = mkOption {
      type = types.bool;
      default = false;
      description = "For the queue: admit the exec_pool_runner role from the sam.fleet exec-pool-db listener's hosts, over TCP by scram. Off, PostgreSQL keeps no TCP listener.";
    };
    drainSecs = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "On a host with a power window (sam.fleet.hosts.<host>.power): how long before its scheduled poweroff the runner stops the running attempt (a session turn parks and pushes its work); it claims only while a run can start 300 s before that.";
    };
    monitoring = mkOption {
      type = types.bool;
      default = false;
      description = "Each slot queries black-pi's Prometheus, Alertmanager and Loki read only, through the host's egress proxy (PROMETHEUS_URL, ALERTMANAGER_URL, LOKI_ADDR in the guest; docs/records/execution-pool-contract.md). The host must be in those listeners' `from`.";
    };
    queueModule = mkOption {
      type = types.bool;
      default = false;
      internal = true;
      description = "Set by exec-pool.nix: the queue's part is imported.";
    };
  };

  config.homelab.execPool.capabilities = lib.mkIf cfg.enable (
    lib.optional (cfg.repos != [ ]) "github"
    ++ lib.optional cfg.monitoring "monitoring"
    ++ lib.optional (!(fleetHost.sleeps or true) && fleetHost.power or null == null) "always-on"
  );

  config.assertions = [
    {
      assertion = cfg.enable || cfg.roles == [ ];
      message = "homelab.execPool.roles: set, but the pool is not enabled.";
    }
  ]
  ++ lib.optionals cfg.enable [
    {
      assertion = has "queue" == cfg.queueModule;
      message = "homelab.execPool.roles: `queue` needs modules/homelab/exec-pool.nix imported, and that module needs it in roles.";
    }
    {
      assertion = !(has "runner") || (cfg.slots > 0 && cfg.agents != [ ]);
      message = "homelab.execPool: a runner needs slots and agents.";
    }
    {
      assertion =
        !(has "runner") || builtins.match "[a-z][a-z0-9-]{0,26}" config.networking.hostName != null;
      message = "homelab.execPool: a runner's networking.hostName must be lower case a-z, 0-9 and -, at most 27, for its slots' host-<hostName> capability.";
    }
    {
      assertion = !(has "runner") || has "queue" != (cfg.queueListener != null);
      message = "homelab.execPool.queueListener: set it for a runner without this host's queue, and only then.";
    }
    {
      assertion = cfg.light.slots <= cfg.slots;
      message = "homelab.execPool.light.slots: more light slots than slots.";
    }
    {
      assertion = !cfg.remoteRunners || has "queue";
      message = "homelab.execPool.remoteRunners: only a queue admits remote runners.";
    }
  ];
}
