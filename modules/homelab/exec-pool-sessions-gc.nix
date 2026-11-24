# Removes the sessions the queue calls eligible (`exec-pool sessions --gc`: final for 7 days, or waiting, idle 14 days
# and fully pushed) from this host's .sessions and .sessions-store into .trash, which frees them a week later; a tree on
# disk the queue does not know (`exec-pool sessions`) is counted, never removed. This host's own trees only, each host
# its runner's queue: acer's own by peer, msi's acer's as exec_pool_runner with its runner's password. The list is read
# as exec_pool by its own unit (exec-pool-sessions-list), which has the network and the credential; root's remover has
# neither and makes only the moves.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.execPool.sessionGc;
  runner = config.homelab.execPool.runner;
  remote = runner.queue != null;
  pkg = pkgs.callPackage ../../pkgs/exec-pool/package.nix { };
  # root's own textfile directory: in exec_pool's exec-pool-metrics a link it planted would turn root's write onto any
  # file under the state dir
  dir = "/run/exec-pool-sessions-gc";
  # root's too, not a StateDirectory: under User=exec_pool that would be the queue role's, a link in it root's write
  state = "/var/lib/exec-pool-sessions-gc";
  # every session, one JSON line each, as exec_pool reads it from the queue; whole or not there
  listDir = "/run/exec-pool-sessions-gc-list";
  list = "${listDir}/sessions";
  lister = pkgs.writeShellApplication {
    name = "exec-pool-sessions-list";
    text = ''
      ${pkg}/bin/exec-pool sessions > ${list}.tmp
      mv -f ${list}.tmp ${list}
    '';
  };
  remover = pkgs.writeShellApplication {
    name = "exec-pool-sessions-gc";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      d=${lib.escapeShellArg config.services.devEnvironments.stateDir}
      state=${state}
      # an id becomes a path under .sessions: anything but a plain name is refused, and dock is the slots' own dir
      valid() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && $1 != dock ]]; }
      [[ -d $d/.trash && ! -L $d/.trash ]] || { echo "exec-pool-sessions-gc: no $d/.trash; nothing removed" >&2; exit 1; }
      # exec_pool's file: a plain one, read at most 16 MiB, then gone, so a failed lister leaves no old list
      [[ -f ${list} && ! -L ${list} ]] || { echo "exec-pool-sessions-gc: no list; nothing removed" >&2; exit 1; }
      all=$(head -c 16777216 ${list})
      rm -f ${list}
      # the queue's eligible, and only with its branch known to hold the tree: a line short of either is not removed
      eligible=$(jq -c 'select(.eligible == true and .handed_back == true)' <<<"$all")
      known=$(jq -r .task_id <<<"$all")
      rc=0 stamp=$(date +%Y%m%d-%H%M%S)
      # a counter file that does not read as a number restarts at 0, which Prometheus reads as a reset
      count() {
        local v
        v=$(cat "$state/removed-$1" 2>/dev/null) || v=0
        [[ $v =~ ^[0-9]+$ ]] || v=0
        echo "$v"
      }
      declare -A removed=([session]=$(count session) [store]=$(count store))
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        id=$(jq -r .task_id <<<"$line" 2>/dev/null) || id=
        if ! valid "$id"; then
          jq -cn --arg id "$id" '{event: "refused", reason: "not a plain task id", task_id: $id}'
          rc=1
          continue
        fi
        # a session dir without its tree is docked in a slot, or between dock and park: neither it nor its copy goes
        if [[ -d $d/.sessions/$id && ! -L $d/.sessions/$id && ! -d $d/.sessions/$id/tree ]]; then
          jq -cn --arg id "$id" '{event: "skipped", reason: "docked", task_id: $id}'
          continue
        fi
        # both places are checked before either moves: one that is a link or a file leaves the id whole
        kinds=() bad=
        for k in session store; do
          src=$d/.sessions/$id
          [[ $k == store ]] && src=$d/.sessions-store/$id
          [[ -e $src || -L $src ]] || continue
          if [[ -L $src || ! -d $src ]]; then bad=$k; fi
          kinds+=("$k")
        done
        if [[ -n $bad ]]; then
          jq -cn --arg id "$id" --arg k "$bad" '{event: "refused", reason: "not a directory", kind: $k, task_id: $id}'
          rc=1
          continue
        fi
        for k in "''${kinds[@]}"; do
          src=$d/.sessions/$id
          [[ $k == store ]] && src=$d/.sessions-store/$id
          to=$d/.trash/$k-$id-$stamp
          if mv -T --no-copy -- "$src" "$to"; then
            removed[$k]=$((removed[$k] + 1))
            jq -cn --argjson s "$line" --arg k "$k" --arg to "$to" \
              '{event: "removed", kind: $k, task_id: $s.task_id, state: $s.state, last_change: $s.last_change, hosts: $s.hosts, trash: $to}'
          else
            rc=1
          fi
        done
      done <<<"$eligible"
      # on disk, unknown to the queue: counted for the operator, never removed
      declare -A orphans=([parked]=0 [store]=0)
      shopt -s nullglob
      for e in "$d"/.sessions/* "$d"/.sessions-store/*; do
        id=''${e##*/}
        [[ $id != dock && -d $e && ! -L $e ]] || continue
        grep -qxF -- "$id" <<<"$known" && continue
        if [[ $e == "$d"/.sessions-store/* ]]; then orphans[store]=$((orphans[store] + 1)); else orphans[parked]=$((orphans[parked] + 1)); fi
      done
      # written once, after the moves: a full disk fails the run here, not between a move and its line
      for k in session store; do echo "''${removed[$k]}" > "$state/removed-$k" || rc=1; done
      {
        for k in session store; do
          printf 'homelab_exec_pool_sessions_removed_total{kind="%s"} %s\n' "$k" "''${removed[$k]}"
        done
        for k in parked store; do
          printf 'homelab_exec_pool_sessions_orphaned{kind="%s"} %s\n' "$k" "''${orphans[$k]}"
        done
      } > ${dir}/sessions-gc.prom.tmp && mv ${dir}/sessions-gc.prom.tmp ${dir}/sessions-gc.prom || rc=1
      exit "$rc"
    '';
  };
in
{
  options.homelab.execPool.sessionGc.enable =
    lib.mkEnableOption "the daily removal of the sessions `exec-pool sessions --gc` lists, into .trash";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = runner.enable;
        message = "homelab.execPool.sessionGc: it removes the trees of this host's runner, which needs homelab.execPool.runner.";
      }
    ];
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
    # before the first run: node-exporter counts a missing directory as a textfile scrape error
    systemd.tmpfiles.rules = [
      "d ${dir} 0755 root root -"
      "d ${state} 0700 root root -"
      "d ${listDir} 0700 exec_pool exec_pool -"
    ];
    systemd.services.exec-pool-sessions-list = {
      description = "List the sessions for exec-pool-sessions-gc, as exec_pool";
      wants = lib.optional remote "network-online.target";
      after =
        if remote then
          [ "network-online.target" ]
        else
          [
            "postgresql.target"
            "exec-pool-migrate.service"
          ];
      requires = lib.optional (!remote) "exec-pool-migrate.service";
      environment.EXEC_POOL_DB = runner.conninfo;
      serviceConfig = {
        Type = "oneshot";
        User = "exec_pool";
        Group = "exec_pool";
        ExecStart = lib.getExe lister;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = !remote;
        RestrictAddressFamilies = [ "AF_UNIX" ] ++ lib.optional remote "AF_INET";
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ReadWritePaths = [ listDir ];
        TimeoutStartSec = 300;
      }
      // lib.optionalAttrs remote {
        LoadCredential = [ "db-password:${config.sops.secrets.exec_pool_runner_password.path}" ];
      };
    };
    systemd.services.exec-pool-sessions-gc = {
      description = "Move the sessions the queue calls eligible into .trash";
      # a fresh list each run: the lister is a oneshot that does not stay active
      requires = [ "exec-pool-sessions-list.service" ];
      after = [ "exec-pool-sessions-list.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe remover;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        NoNewPrivileges = true;
        # the renames out of exec-pool-sync's 0700 store and into root's 0700 .trash
        CapabilityBoundingSet = [ "CAP_DAC_OVERRIDE" ];
        # "-": a host without the state dir reaches the script's own .trash check, not a namespace failure
        ReadWritePaths = [
          "-${config.services.devEnvironments.stateDir}"
          dir
          state
          listDir
        ];
        TimeoutStartSec = 600;
      };
    };
    systemd.timers.exec-pool-sessions-gc = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
