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
  lightSlots = lib.drop (cfg.slots - cfg.light.slots) slotNames;
  isLight = n: lib.elem n lightSlots;
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
    services.devEnvironments.instances = lib.genAttrs slotNames (n: {
      agent = "none";
      # the slots' headless Claude reports its compactions and tokens per slot (worker), which #626 compares
      telemetry = config.sam.profile.nativeOtel && cfg.agents != [ ];
      headlessAgents = cfg.agents;
      egress.github.repos = cfg.repos;
      egress.monitoring = cfg.monitoring;
      # the runner's runtime directory (exec-pool-runner.nix)
      egress.github.ownRefs = lib.mkIf cfg.ownRefsOnly "/run/exec-pool-runner/${n}/manifest.json";
      sessionDock = true;
      rootInGuest = cfg.slot.privateUsers;
      # a task's fetches never read entries an earlier task in any slot planted
      ownNixCache = true;
      # each attempt's workspace (pkgs/exec-pool/src/workspace.rs): throwaway, so its checkout never holds the reset
      scratch = [ "attempts" ];
      memory.reserved = if isLight n then cfg.light.memory else cfg.slot.memory;
      cpu.reserved = if isLight n then cfg.light.cpu else cfg.slot.cpu;
    });
    # only a declared, running slot: a paused or forced-out one would get a unit with a quota and no ExecStart
    systemd.services =
      lib.genAttrs
        (map (n: "container@${n}") (
          lib.filter (n: dev.instances ? ${n} && !dev.instances.${n}.paused) lightSlots
        ))
        (_: {
          serviceConfig.CPUQuota = cfg.light.cpuQuota;
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
        {
          devEnvironment,
          config,
          pkgs,
          ...
        }:
        let
          # The slots share one environments.slice (#827): a task's own evaluation takes the light-work lane the push
          # hook's takes, and never a compile or a program that may take heavy (pool-merge-check: heavy, then light).
          # A caller already holding its locks sets WORK_LOCKS_HELD=1 (pool_merge_check.py), or it waits on itself.
          lane =
            name: real: text:
            lib.hiPrio (
              pkgs.writeShellScriptBin name ''
                light() {
                  WORK_LOCKS_HELD=1 ${pkgs.util-linux}/bin/flock -o -w 900 -E 75 /run/work-locks/light-work.lock "$@"
                  rc=$?
                  [ "$rc" -ne 75 ] || echo "${name}: /run/work-locks/light-work.lock still held after 900 s" >&2
                  return "$rc"
                }
                if [ -z "''${WORK_LOCKS_HELD:-}" ] && [ -e /run/work-locks/light-work.lock ]; then
                  ${text}
                fi
                exec ${real} "$@"
              ''
            );
          nix = lib.getExe config.nix.package;
          devenv = lib.getExe pkgs.devenv;
        in
        lib.mkIf (lib.elem devEnvironment.name slotNames) {
          environment.systemPackages = [
            poolWait
            (lane "nix" nix ''
              # the subcommand after any `--option k v`, which goes on to the evaluation
              n=1
              while [ "''${!n:-}" = --option ]; do n=$((n + 3)); done
              m=$((n + 1))
              case ''${!n:-} in
                eval | path-info | derivation) light ${nix} "$@"; exit ;;
                # check builds as it evaluates: wholly under the lock
                flake) case ''${!m:-} in show | metadata | info | check) light ${nix} "$@"; exit ;; esac ;;
                build)
                  all=("$@")
                  # each flake attribute's drvPath, or each attribute's of one --expr or --file, under the lock, its build
                  # outside; another form runs unlocked
                  flags=("''${@:1:n-1}") evalflags=("''${@:1:n-1}") attrs=() src=() whole=
                  shift "$n"
                  while [ $# -gt 0 ]; do
                    case $1 in
                      -o | --out-link) flags+=("$1" "''${2:-}"); shift ;;
                      --expr) [ ''${#src[@]} -eq 0 ] || whole=1; src=(--expr "''${2:-}"$'\n'); shift ;;
                      -f | --file) [ ''${#src[@]} -eq 0 ] || whole=1; src=(--file "''${2:-}"); shift ;;
                      --arg | --argstr) evalflags+=("$1" "''${2:-}" "''${3:-}"); shift 2 ;;
                      --impure | --show-trace | --no-write-lock-file) flags+=("$1"); evalflags+=("$1") ;;
                      --no-link | -L | --print-build-logs | --print-out-paths | --keep-going | -k | --json | --rebuild | --dry-run) flags+=("$1") ;;
                      -*) whole=1 ;;
                      *^* | *'#') whole=1 ;;
                      *) attrs+=("$1") ;;
                    esac
                    shift
                  done
                  # with --expr or --file a positional is an attribute of it, without one a flake reference
                  for a in "''${attrs[@]}"; do
                    case $a in *'#'*) [ ''${#src[@]} -eq 0 ] || whole=1 ;; *) [ ''${#src[@]} -gt 0 ] || whole=1 ;; esac
                  done
                  [ -z "$whole" ] && [ $((''${#attrs[@]} + ''${#src[@]})) -gt 0 ] || exec ${nix} "''${all[@]}"
                  # drv^ the outputs nix build would pick (outputSpecified, then meta.outputsToInstall), not ^* (every
                  # output); with neither, a flake attribute's out and a file's or expression's every output
                  fallback='[ "out" ]'
                  [ ''${#src[@]} -eq 0 ] || fallback='d.outputs or [ d.outputName ]'
                  apply="d: d.drvPath + \"^\" + builtins.concatStringsSep \",\" (if d.outputSpecified or false then [ d.outputName ] else d.meta.outputsToInstall or $fallback)"
                  set -- build "''${flags[@]}"
                  if [ ''${#attrs[@]} -eq 0 ]; then
                    drv=$(light ${nix} eval "''${evalflags[@]}" --raw "''${src[@]}" --apply "$apply") || exit
                    set -- "$@" "$drv"
                  fi
                  for a in "''${attrs[@]}"; do
                    drv=$(light ${nix} eval "''${evalflags[@]}" --raw "''${src[@]}" "$a" --apply "$apply") || exit
                    set -- "$@" "$drv"
                  done
                  exec ${nix} "$@" ;;
              esac
            '')
            (lane "nix-instantiate" "${config.nix.package}/bin/nix-instantiate" ''
              light ${config.nix.package}/bin/nix-instantiate "$@"; exit
            '')
            # its drvs instantiated under the lock and rooted until built (with --add-root nix-instantiate prints the
            # roots, a drv!output for an output not out), then nix-build on them: the same out-links and output paths
            (lane "nix-build" "${config.nix.package}/bin/nix-build" ''
              inst=() flags=()
              for ((i = 1; i <= $#; i++)); do
                j=$((i + 1)) k=$((i + 2))
                case ''${!i} in
                  -A | --attr | -I | --include) inst+=("''${!i}" "''${!j:-}"); i=$j ;;
                  --arg | --argstr) inst+=("''${!i}" "''${!j:-}" "''${!k:-}"); i=$k ;;
                  --option) inst+=("''${!i}" "''${!j:-}" "''${!k:-}"); flags+=("''${!i}" "''${!j:-}" "''${!k:-}"); i=$k ;;
                  -o | --out-link | -j | --max-jobs | --cores) flags+=("''${!i}" "''${!j:-}"); i=$j ;;
                  -E | --expr | --show-trace | --impure) inst+=("''${!i}") ;;
                  --no-out-link | -Q | --no-build-output | -K | --keep-failed | -k | --keep-going | -L | --print-build-logs | --dry-run) flags+=("''${!i}") ;;
                  -* | /nix/store/*) exec ${config.nix.package}/bin/nix-build "$@" ;;
                  *) inst+=("''${!i}") ;;
                esac
              done
              roots=$(${pkgs.coreutils}/bin/mktemp -d) || exit
              trap '${pkgs.coreutils}/bin/rm -rf "$roots"' EXIT
              out=$(light ${config.nix.package}/bin/nix-instantiate --add-root "$roots/drv" "''${inst[@]}") || exit
              [ -n "$out" ] || exit 0
              drvs=()
              while IFS= read -r p; do
                o=
                case $p in *!*) o=!''${p##*!} p=''${p%!*} ;; esac
                drvs+=("$(${pkgs.coreutils}/bin/readlink -f "$p")$o")
              done <<<"$out"
              ${config.nix.package}/bin/nix-build "''${flags[@]}" "''${drvs[@]}"
              exit
            '')
            # devenv evaluates in-process and caches it: under the lock its eval, or a warm `shell -- true` for a
            # command that runs a task or a shell, which then evaluates from that cache
            (lane "devenv" devenv ''
              case ''${1:-} in
                eval | info | search | direnv-export) light ${devenv} "$@"; exit ;;
                shell | tasks | test | up | processes | build) light ${devenv} shell -- true >&2 || : ;;
              esac
            '')
          ];
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
        assertion = cfg.ownRefsOnly -> lib.elem "runner" cfg.roles;
        message = "homelab.execPool.ownRefsOnly: a slot's task is read from its runner's manifest, and this host has no runner role.";
      }
      {
        assertion = collisions == [ ];
        message = "homelab.execPool: ${lib.concatStringsSep ", " collisions} is a pool slot's name, also declared in sam.workers.instances or retired.";
      }
    ];
  };
}
