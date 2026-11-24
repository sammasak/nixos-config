# Removes the sessions the queue calls eligible (`exec-pool sessions --gc`: final for 7 days, or waiting, idle 14 days
# and fully pushed) from this host's .sessions and .sessions-store into .trash, which frees them a week later; a tree on
# disk the queue does not know (`exec-pool sessions`) is counted, never removed. This host's own trees only: msi's
# parked trees wait for a remover there. Off until the CLI has both commands.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.execPool.sessionGc;
  pkg = pkgs.callPackage ../../pkgs/exec-pool/package.nix { };
  # root's own textfile directory: in exec_pool's exec-pool-metrics a link it planted would turn root's write onto any
  # file under the state dir
  dir = "/run/exec-pool-sessions-gc";
  remover = pkgs.writeShellApplication {
    name = "exec-pool-sessions-gc";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      d=${lib.escapeShellArg config.services.devEnvironments.stateDir}
      state=$STATE_DIRECTORY
      # the CLI as the queue's own role, by peer; root keeps only the moves
      cli() { setpriv --reuid=exec_pool --regid=exec_pool --clear-groups -- ${lib.getExe pkg} sessions "$@"; }
      # an id becomes a path under .sessions: anything but a plain name is refused, and dock is the slots' own dir
      valid() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && $1 != dock ]]; }
      [[ -d $d/.trash && ! -L $d/.trash ]] || { echo "exec-pool-sessions-gc: no $d/.trash; nothing removed" >&2; exit 1; }
      eligible=$(cli --gc)
      known=$(cli | jq -r .task_id)
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
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
    # before the first run: node-exporter counts a missing directory as a textfile scrape error
    systemd.tmpfiles.rules = [ "d ${dir} 0755 root root -" ];
    systemd.services.exec-pool-sessions-gc = {
      description = "Move the sessions the queue calls eligible into .trash";
      after = [
        "postgresql.target"
        "exec-pool-migrate.service"
      ];
      requires = [ "exec-pool-migrate.service" ];
      environment.EXEC_POOL_DB = "host=/run/postgresql dbname=exec_pool user=exec_pool";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe remover;
        StateDirectory = "exec-pool-sessions-gc";
        StateDirectoryMode = "0700";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        # the renames out of exec-pool-sync's 0700 store and into root's 0700 .trash, and setpriv's drop to exec_pool
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE"
          "CAP_SETUID"
          "CAP_SETGID"
        ];
        # "-": a host without the state dir reaches the script's own .trash check, not a namespace failure
        ReadWritePaths = [
          "-${config.services.devEnvironments.stateDir}"
          dir
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
