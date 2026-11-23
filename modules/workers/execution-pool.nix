# The execution pool (#650, docs/records/execution-pool-contract.md): `slots` reusable environments pool1..poolN with
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
  slots = map (n: dev.instances.${n}) slotNames;
  # names any other module declares in instances (sam.workers.instances is an alias of it)
  declaredElsewhere = lib.unique (
    lib.concatMap (d: lib.attrNames d.value) (
      lib.filter (
        d: !lib.hasSuffix "/modules/workers/execution-pool.nix" d.file
      ) options.services.devEnvironments.instances.definitionsWithLocations
    )
  );
  collisions = lib.intersectLists slotNames (declaredElsewhere ++ dev.retired);
  sum = lib.foldl' (s: w: s + w.memory.reserved) 0;
  named = lib.filter (w: !w.paused && !lib.elem w.name slotNames) (lib.attrValues dev.instances);
  mib = b: "${toString (b / 1048576)}M";

  # From the units, not from a roster: a slot is what systemd and its per-container profile say it is.
  inventory = pkgs.writeShellApplication {
    name = "worker-pool-inventory";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      for n in ${lib.concatStringsSep " " slotNames}; do
        u=container@$n.service
        jq -cn --arg slot "$n" \
          --arg state "$(systemctl show -P ActiveState "$u")" \
          --arg sub "$(systemctl show -P SubState "$u")" \
          --arg closure "$(readlink -e /nix/var/nix/profiles/per-container/"$n"/system || true)" \
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
      description = "How many slots, named pool1..pool<slots>; each reserves memory.reserved of sam.workers.pool.memory.";
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
      description = "Which of services.devEnvironments.credentials a slot may hold; none by default, as msi's t1.";
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
      inherit (cfg) credentials rootInGuest;
      memory.reserved = cfg.memory.reserved;
      cpu.reserved = cfg.cpu.reserved;
    });

    environment.systemPackages = lib.optional (cfg.slots > 0) inventory;

    assertions = [
      {
        assertion = collisions == [ ];
        message = "sam.workers.executionPool: ${lib.concatStringsSep ", " collisions} is a pool slot's name, also declared in sam.workers.instances or retired.";
      }
      {
        assertion = sum slots + sum named <= dev.pool.memory;
        message = "sam.workers.executionPool: ${toString cfg.slots} slots of ${cfg.memory.reserved} (${mib (sum slots)}) and the named instances' ${mib (sum named)} exceed sam.workers.pool.memory ${mib dev.pool.memory}.";
      }
    ];
  };
}
