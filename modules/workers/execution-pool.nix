# The execution pool's slots (homelab.execPool, docs/records/execution-pool-contract.md): `slots` reusable environments pool1..poolN with
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
  cfg = config.homelab.execPool;
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
  # pool-wait alone on the guests' PATH, not the queue's and runner's binaries
  poolWait = pkgs.runCommand "pool-wait" { } ''
    install -D ${pkgs.callPackage ../../pkgs/exec-pool/package.nix { }}/bin/pool-wait $out/bin/pool-wait
  '';

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
  imports = [ ../homelab/exec-pool-options.nix ];

  config = lib.mkIf cfg.enable {
    services.devEnvironments.instances = lib.genAttrs slotNames (_: {
      agent = "none";
      # the slots' headless Claude reports its compactions and tokens per slot (worker), which #626 compares
      telemetry = config.sam.profile.nativeOtel && cfg.agents != [ ];
      headlessAgents = cfg.agents;
      egress.github.repos = cfg.repos;
      egress.monitoring = cfg.monitoring;
      sessionDock = true;
      rootInGuest = cfg.slot.privateUsers;
      # a task's fetches never read entries an earlier task in any slot planted
      ownNixCache = true;
      # each attempt's workspace (pkgs/exec-pool/src/workspace.rs): throwaway, so its checkout never holds the reset
      scratch = [ "attempts" ];
      memory.reserved = cfg.slot.memory;
      cpu.reserved = cfg.slot.cpu;
    });

    # A slot's reset runs once per task turn, seconds apart in a session; under systemd's default limit a burst of
    # refused resets (the runner retries each) fails the unit. A drop-in of the shared template's own instance: a
    # systemd.services one would also set its PATH.
    systemd.units = lib.genAttrs (map (n: "dev-env-reset@${n}.service") slotNames) (_: {
      overrideStrategy = "asDropin";
      text = ''
        [Unit]
        StartLimitIntervalSec=0
      '';
    });

    environment.systemPackages = lib.optional (cfg.slots > 0) inventory;

    services.devEnvironments.guestModules = [
      (
        { devEnvironment, ... }:
        lib.mkIf (lib.elem devEnvironment.name slotNames) {
          environment.systemPackages = [ poolWait ];
          # A slot runs task text: none of the host user's groups (wheel, kvm, input) and no sudo, whose setuid
          # wrapper is host root's in a slot without privateUsers. mkForce: core/users.nix and rootInGuest add them.
          users.users.${dev.user}.extraGroups = lib.mkForce [ ];
          security.sudo.enable = false;
        }
      )
    ];

    # over-reservation is the core's assertion (pool.memory), slots included
    assertions = [
      {
        # a host's own forced instances may drop the slots
        assertion = lib.all (i: !lib.elem "id_ed25519" i.credentials && i.egress.github.repos != [ ]) (
          lib.attrValues (
            lib.getAttrs (lib.intersectLists slotNames (lib.attrNames dev.instances)) dev.instances
          )
        );
        message = "homelab.execPool: a slot reaches GitHub through the host's proxy (repos), never with the host user's SSH key (slot.credentials).";
      }
      {
        assertion = collisions == [ ];
        message = "homelab.execPool: ${lib.concatStringsSep ", " collisions} is a pool slot's name, also declared in sam.workers.instances or retired.";
      }
    ];
  };
}
