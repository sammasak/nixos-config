# The execution pool (docs/records/execution-pool-contract.md): `slots` reusable environments pool1..poolN with
# no agent and no prompt, generated into the same instances as the named ones, so the core's pool ceiling, reserves,
# rootInGuest, reset and retire apply to them unchanged. The count changes in a reviewed deploy; a task is assigned to
# a slot and released by dev-env-reset@<slot>, which switches nothing.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers.executionPool;
  dev = config.services.devEnvironments;
  slotNames = map (n: "pool${toString n}") (lib.range 1 cfg.slots);
  # names any other module declares in instances (sam.workers.instances is an alias of it)
  declaredElsewhere = lib.unique (
    lib.concatMap (d: lib.attrNames d.value) (
      lib.filter (
        d: !lib.hasSuffix "/modules/workers/execution-pool.nix" d.file
      ) options.services.devEnvironments.instances.definitionsWithLocations
    )
  );
  collisions = lib.intersectLists slotNames (declaredElsewhere ++ dev.retired);

  # State, closure and limits from the units and the container's conf, not a roster; the slot names are this generation's.
  inventory = pkgs.writeShellApplication {
    name = "worker-pool-inventory";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      slots=(${lib.escapeShellArgs slotNames})
      for n in "''${slots[@]}"; do
        u=container@$n.service
        jq -cn --arg slot "$n" \
          --arg state "$(systemctl show -P ActiveState "$u")" \
          --arg sub "$(systemctl show -P SubState "$u")" \
          --arg closure "$(sed -n 's/^SYSTEM_PATH=//p' /etc/nixos-containers/"$n".conf)" \
          --arg memoryMin "$(systemctl show -P MemoryMin "$u")" \
          --arg memoryLow "$(systemctl show -P MemoryLow "$u")" \
          --arg cpuWeight "$(systemctl show -P CPUWeight "$u")" \
          --arg slice "$(systemctl show -P Slice "$u")" \
          '{ $slot, $state, $sub, $closure, memory: { min: $memoryMin, low: $memoryLow }, cpu: { weight: $cpuWeight }, $slice }'
      done
    '';
  };
in
{
  options.sam.workers.executionPool = {
    enable = lib.mkEnableOption "the execution pool's reusable slots";
    slots = mkOption {
      type = types.ints.unsigned;
      default = 0;
      description = "How many slots, named pool1..pool<slots>; each reserves memory.reserved of sam.workers.pool.memory. A slot dropped by a lower count keeps its home: retire it.";
    };
    memory.reserved = mkOption {
      type = types.strMatching "[1-9][0-9]*[KMGT]?";
      default = "2G";
      description = "Each slot's MemoryMin, as an instance's memory.reserved.";
    };
    cpu.reserved = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Each slot's cores, as an instance's cpu.reserved.";
    };
    credentials = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "id_ed25519" ];
      description = "Which of services.devEnvironments.credentials a slot may hold; none by default.";
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
      example = [
        "claude"
        "codex"
        "pi"
      ];
      description = "Agents a task may run in a slot, each with its egress proxy and no credential in the guest (anthropic, openai with sam.workers.codexAuthFile, llm-gateway with the host's Pi key); the slot's own agent stays none, so no session starts.";
    };
    rootInGuest = mkOption {
      type = types.bool;
      default = false;
      description = "Each slot's rootInGuest.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.devEnvironments.instances = lib.genAttrs slotNames (_: {
      agent = "none";
      # nativeOtel's default would bind the OTLP proxy socket into a slot with no agent to send
      telemetry = false;
      headlessAgents = cfg.agents;
      inherit (cfg) credentials rootInGuest;
      sessionDock = true;
      # each attempt's workspace (pkgs/exec-pool/src/workspace.rs): throwaway, so its checkout never holds the reset
      scratch = [ "attempts" ];
      memory.reserved = cfg.memory.reserved;
      cpu.reserved = cfg.cpu.reserved;
    });

    # A slot restarts its container and runs its reset once per task turn, a few seconds apart in a session: a start
    # limit fails the slot on the fourth turn in ten minutes (container@pool1 on acer). Named workers keep theirs.
    systemd.services = lib.genAttrs (map (n: "container@${n}") slotNames) (_: {
      startLimitIntervalSec = lib.mkForce 0;
    });
    # a drop-in of the shared template's own instance: a systemd.services one would also set its PATH
    systemd.units = lib.genAttrs (map (n: "dev-env-reset@${n}.service") slotNames) (_: {
      overrideStrategy = "asDropin";
      text = ''
        [Unit]
        StartLimitIntervalSec=0
      '';
    });

    environment.systemPackages = lib.optional (cfg.slots > 0) inventory;

    # over-reservation is the core's assertion (pool.memory), slots included
    assertions = [
      {
        assertion = collisions == [ ];
        message = "sam.workers.executionPool: ${lib.concatStringsSep ", " collisions} is a pool slot's name, also declared in sam.workers.instances or retired.";
      }
    ];
  };
}
