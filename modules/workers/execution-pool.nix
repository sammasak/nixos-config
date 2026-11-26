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
                  # CLASS COMMAND...: no evaluation starts while the scheduled gate holds the heavy lock (#835): its
                  # scheduled-gate.lock (pkgs/heavy-lock) is waited out first, within the same 900 s. One already running
                  # goes on: held shared across it, overlapping slots would starve the gate's exclusive take. The light
                  # lock is this shell's, closed in COMMAND as flock -o would; each call, a timed-out one included, is one
                  # kind=lock record of its wait (the gate's included) apart from its hold, in the spool the host ships.
                  local class=$1 start=$SECONDS gate=/run/work-locks/scheduled-gate.lock w rc=0 fd="" held
                  shift
                  if [ -e "$gate" ] && ! ${pkgs.util-linux}/bin/flock -s -n "$gate" true; then
                    echo "${name}: waiting for the scheduled gate, which holds /run/work-locks/heavy-work.lock" >&2
                    ${pkgs.util-linux}/bin/flock -s -w 900 -E 75 "$gate" true || rc=$?
                    [ "$rc" -ne 75 ] || echo "${name}: the scheduled gate still holds $gate after 900 s" >&2
                  fi
                  if [ "$rc" -eq 0 ]; then
                    w=$((900 - SECONDS + start))
                    exec {fd}</run/work-locks/light-work.lock
                    ${pkgs.util-linux}/bin/flock -w $((w > 0 ? w : 0)) -E 75 "$fd" || rc=$?
                    [ "$rc" -ne 75 ] || echo "${name}: /run/work-locks/light-work.lock still held after 900 s" >&2
                  fi
                  held=$SECONDS
                  if [ "$rc" -eq 0 ]; then
                    WORK_LOCKS_HELD=1 "$@" {fd}<&-
                    rc=$?
                  fi
                  [ -z "$fd" ] || exec {fd}<&-
                  PLATFORM_RECORD_SHIPPER=host PLATFORM_RECORD_SPOOL=${spool} ${lib.getExe record} lock lane=light class="$class" wait_seconds=$((held - start)) seconds=$((SECONDS - held)) rc="$rc" >&2 || :
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
          record = pkgs.callPackage ../../pkgs/platform-record/package.nix { };
          # the spool the host ships is the guest user's own (scripts/guest-records.py), not the HOME a runner step gets
          # (an attempt's under attempts/, a session turn's /session/cur/home: pkgs/exec-pool/src/workspace.rs)
          spool = "${config.users.users.${dev.user}.home}/.local/state/platform-records";
          cargoJobs = toString (
            lib.max 1 (dev.instances.${devEnvironment.name}.memory.reserved / 1073741824)
          );
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
                eval | path-info | derivation) light "nix-''${!n}" ${nix} "$@"; exit ;;
                # check builds as it evaluates: wholly under the lock
                flake) case ''${!m:-} in show | metadata | info | check) light "nix-flake-''${!m}" ${nix} "$@"; exit ;; esac ;;
                build)
                  all=("$@")
                  # each flake attribute's drvPath, or each attribute's of one --expr or --file, under the lock, its build
                  # outside; another form runs unlocked
                  flags=("''${@:1:n-1}") evalflags=("''${@:1:n-1}") attrs=() src=() whole=
                  shift "$n"
                  while [ $# -gt 0 ]; do
                    case $1 in
                      # a value missing: nix's own refusal
                      -o | --out-link | --expr | -f | --file | --arg | --argstr) [ $# -ge 2 ] || whole=1 ;;&
                      --arg | --argstr) [ $# -ge 3 ] || whole=1 ;;&
                      -o | --out-link) flags+=("$1" "''${2:-}"); shift ;;
                      # the newline ends a trailing comment in E, which nix build reads but --apply would extend
                      --expr) [ ''${#src[@]} -eq 0 ] || whole=1; src=(--expr "''${2:-}"$'\n'); shift ;;
                      -f | --file) [ ''${#src[@]} -eq 0 ] || whole=1; src=(--file "''${2:-}"); shift ;;
                      --arg | --argstr) evalflags+=("$1" "''${2:-}" "''${3:-}"); shift; shift ;;
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
                  # output); with neither, a flake attribute's out and a file's or expression's every output. Anything but
                  # one derivation (a function to call, a set or list of them) prints nothing: nix build runs it whole.
                  fallback='[ "out" ]'
                  [ ''${#src[@]} -eq 0 ] || fallback='d.outputs or [ d.outputName ]'
                  apply="d: if builtins.isAttrs d && d.type or null == \"derivation\" then d.drvPath + \"^\" + builtins.concatStringsSep \",\" (if d.outputSpecified or false then [ d.outputName ] else d.meta.outputsToInstall or $fallback) else \"\""
                  [ ''${#attrs[@]} -gt 0 ] || attrs=("")
                  # every evaluation in one hold, not a wait on the lock per attribute. A drv is unrooted from its
                  # evaluation to the build (a guest's roots dangle on the host): a host collection between them fails it.
                  picks=$(light nix-build-eval ${pkgs.bash}/bin/bash -c '
                    nix=$1 apply=$2 k=$3; shift 3; flags=("''${@:1:k}"); shift "$k"; s=$1; shift; src=("''${@:1:s}"); shift "$s"
                    for a; do
                      d=$("$nix" eval "''${flags[@]}" --raw "''${src[@]}" "$a" --apply "$apply") || exit
                      [ -n "$d" ] || exit 64
                      echo "$d"
                    done
                  ' pick ${nix} "$apply" ''${#evalflags[@]} "''${evalflags[@]}" ''${#src[@]} "''${src[@]}" "''${attrs[@]}")
                  rc=$?
                  [ "$rc" -ne 64 ] || exec ${nix} "''${all[@]}"
                  [ "$rc" -eq 0 ] || exit "$rc"
                  readarray -t drvs <<<"$picks"
                  exec ${nix} build "''${flags[@]}" "''${drvs[@]}" ;;
              esac
            '')
            (lane "nix-instantiate" "${config.nix.package}/bin/nix-instantiate" ''
              light nix-instantiate ${config.nix.package}/bin/nix-instantiate "$@"; exit
            '')
            # its drvs instantiated under the lock, then nix-build on them: the same out-links and output paths. --add-root
            # only silences nix-instantiate's warning (a guest's roots dangle on the host); it prints the roots, a
            # drv!output for an output not out
            (lane "nix-build" "${config.nix.package}/bin/nix-build" ''
              inst=() flags=()
              for ((i = 1; i <= $#; i++)); do
                j=$((i + 1)) k=$((i + 2))
                # a value missing: nix-build's own refusal
                case ''${!i} in
                  -A | --attr | -I | --include | -o | --out-link | -j | --max-jobs | --cores) [ "$j" -le $# ] || exec ${config.nix.package}/bin/nix-build "$@" ;;&
                  --arg | --argstr | --option) [ "$k" -le $# ] || exec ${config.nix.package}/bin/nix-build "$@" ;;&
                  -A | --attr | -I | --include) inst+=("''${!i}" "''${!j:-}"); i=$j ;;
                  --arg | --argstr) inst+=("''${!i}" "''${!j:-}" "''${!k:-}"); i=$k ;;
                  --option) inst+=("''${!i}" "''${!j:-}" "''${!k:-}"); flags+=("''${!i}" "''${!j:-}" "''${!k:-}"); i=$k ;;
                  -o | --out-link | -j | --max-jobs | --cores) flags+=("''${!i}" "''${!j:-}"); i=$j ;;
                  -E | --expr | --show-trace | --impure) inst+=("''${!i}") ;;
                  --no-out-link | -Q | --no-build-output | -K | --keep-failed | -k | --keep-going | -L | --print-build-logs | --dry-run) flags+=("''${!i}") ;;
                  # a drv, or a link to one, nix-build builds as it is
                  -* | *.drv | *.drv!*) exec ${config.nix.package}/bin/nix-build "$@" ;;
                  *) [[ $(${pkgs.coreutils}/bin/readlink -f -- "''${!i}") != /nix/store/*.drv ]] || exec ${config.nix.package}/bin/nix-build "$@"; inst+=("''${!i}") ;;
                esac
              done
              roots=$(${pkgs.coreutils}/bin/mktemp -d) || exit
              trap '${pkgs.coreutils}/bin/rm -rf "$roots"' EXIT
              out=$(light nix-build-instantiate ${config.nix.package}/bin/nix-instantiate --add-root "$roots/drv" "''${inst[@]}") || exit
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
            # command that runs a task or a shell, whose shell then evaluates from that cache. No warm-up while the stamp
            # matches what devenv's cache keys on: the files its last evaluation read (.devenv/input-paths.txt, its
            # direnv watch list: devenv.nix, .yaml, .lock, the local overrides and every file they import), the env
            # vars it read (eval_env_input in its db, and those this repo's cache holds), the db itself (a deleted or
            # recreated one is cold) and devenv. A key that moved during the warm-up, a missing list or db or a failed
            # warm-up writes no stamp, so the next call warms up again.
            (lane "devenv" devenv ''
              warm_key() {
                local f v db=$1/nix-eval-cache.db files=()
                [ -f "$1/input-paths.txt" ] && [ -f "$db" ] || return
                {
                  echo ${devenv}
                  ${pkgs.coreutils}/bin/stat -c 'db %d:%i' "$db"
                  { printf '%s\n' HOME DEVENV_CONTAINER SECRETSPEC_SECRETS NIXPKGS_ALLOW_UNFREE NIXPKGS_ALLOW_INSECURE \
                      NIXPKGS_ALLOW_BROKEN NIXPKGS_ALLOW_NONSOURCE NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM
                    ${pkgs.sqlite}/bin/sqlite3 -readonly "$db" 'SELECT DISTINCT name FROM eval_env_input' 2>/dev/null
                  } | ${pkgs.coreutils}/bin/sort -u | while IFS= read -r v; do
                    case $v in "" | [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
                    if [ -n "''${!v+set}" ]; then printf 'env %s=%s\n' "$v" "''${!v}"; else echo "env $v unset"; fi
                  done
                  while IFS= read -r f; do
                    if [ -d "$f" ]; then echo "$f dir $(${pkgs.coreutils}/bin/ls -A "$f" | ${pkgs.coreutils}/bin/sha256sum)"
                    elif [ -e "$f" ]; then files+=("$f")
                    else echo "$f absent"; fi
                  done <"$1/input-paths.txt"
                  [ ''${#files[@]} -eq 0 ] || ${pkgs.coreutils}/bin/sha256sum -- "''${files[@]}" 2>/dev/null
                } | ${pkgs.coreutils}/bin/sha256sum
              }
              case ''${1:-} in
                eval | info | search | direnv-export) light "devenv-$1" ${devenv} "$@"; exit ;;
                shell | tasks | test | up | processes | build)
                  # devenv's root: the nearest directory up with a devenv.nix, as devenv finds it
                  d=$PWD
                  while [ "$d" != / ] && [ ! -e "$d/devenv.nix" ]; do d=''${d%/*} d=''${d:-/}; done
                  d=$d/.devenv
                  k=$(warm_key "$d")
                  if [ -z "$k" ] || [ "$(${pkgs.coreutils}/bin/cat "$d/light-warm" 2>/dev/null)" != "$k" ]; then
                    if light devenv-warm-up ${devenv} shell -- true >&2 && [ -n "$k" ] && [ "$(warm_key "$d")" = "$k" ]; then
                      { echo "$k" >"$d/light-warm.$$" && ${pkgs.coreutils}/bin/mv "$d/light-warm.$$" "$d/light-warm"; } 2>/dev/null || :
                    fi
                  fi ;;
              esac
            '')
          ];
          # Not a cargo lane: in a devenv shell cargo is the profile's, ahead of this PATH, and every cargo reads this.
          # About a GiB a rustc: a slot compiles within its reserve, and the reserves fit the shared slice (#827). A
          # best effort (`-j` overrides it); the slice's MemoryMax stays the limit. Logins read sessionVariables; the
          # runner's steps are transient systemd-run units with a filtered environment, which get the manager's
          # DefaultEnvironment (not globalEnvironment: that is only the declared units' Environment=).
          environment.sessionVariables.CARGO_BUILD_JOBS = cargoJobs;
          systemd.settings.Manager.DefaultEnvironment = "CARGO_BUILD_JOBS=${cargoJobs}";
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
