# The session trees of the layout before the state moved to the remote (a session's .sessions/<hex>/tree and its copy in
# .sessions-store/<hex>): nothing reads them any more. A tree whose session is cancelled, or whose last turn's branch
# held it whole (session_gc's handed_back: the branch head is on the remote), is moved into .trash, freed a week later;
# any other, or one the queue does not know, is kept and counted. .sessions-store goes once nothing is left in it. The
# list is read as exec_pool by its own unit, which has the network and the credential; root's remover has neither.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.execPool;
  remote = cfg.queueListener != null;
  listener = config.sam.fleet.listeners.${cfg.queueListener};
  db =
    if remote then
      "host=${
        config.sam.fleet.hosts.${listener.host}.address
      } port=${toString listener.port} dbname=exec_pool user=exec_pool_runner"
    else
      "host=/run/postgresql dbname=exec_pool user=exec_pool";
  # root's own textfile directory and state: in exec_pool's reach a link it planted would turn root's write anywhere
  dir = "/run/exec-pool-legacy-sessions";
  state = "/var/lib/exec-pool-legacy-sessions";
  listDir = "/run/exec-pool-legacy-sessions-list";
  list = "${listDir}/sessions";
  lister = pkgs.writeShellApplication {
    name = "exec-pool-legacy-sessions-list";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.postgresql
    ];
    text = ''
      if [[ -n ''${CREDENTIALS_DIRECTORY:-} ]]; then
        PGPASSWORD=$(cat "$CREDENTIALS_DIRECTORY/db-password")
        export PGPASSWORD
      fi
      # dir: the runner's name for the session's directory, two lowercase hex digits per byte of the task id
      psql ${lib.escapeShellArg db} -v ON_ERROR_STOP=1 -XAtc \
        "SELECT json_build_object('task_id', task, 'dir', encode(convert_to(task, 'UTF8'), 'hex'), 'state', state,
           'handed_back', handed_back IS TRUE) FROM session_gc" > ${list}.tmp
      mv -f ${list}.tmp ${list}
    '';
  };
  remover = pkgs.writeShellApplication {
    name = "exec-pool-legacy-sessions";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      d=${lib.escapeShellArg config.services.devEnvironments.stateDir}
      valid() { [[ $1 =~ ^([0-9a-f]{2}){1,128}$ ]]; }
      [[ -d $d/.trash && ! -L $d/.trash ]] || { echo "exec-pool-legacy-sessions: no $d/.trash; nothing removed" >&2; exit 1; }
      # exec_pool's file: a plain one, read at most 16 MiB, then gone, so a failed lister leaves no old list
      [[ -f ${list} && ! -L ${list} ]] || { echo "exec-pool-legacy-sessions: no list; nothing removed" >&2; exit 1; }
      all=$(head -c 16777216 ${list})
      rm -f ${list}
      # the dirs that may go: a cancelled session's, or one whose last turn handed its whole tree back on its branch
      gone=$(jq -r 'select(.state == "cancelled" or .handed_back == true) | .dir' <<<"$all")
      known=$(jq -r .dir <<<"$all")
      rc=0 stamp=$(date +%Y%m%d-%H%M%S)
      v=$(cat ${state}/removed 2>/dev/null) || v=0
      [[ $v =~ ^[0-9]+$ ]] || v=0
      removed=$v
      declare -A kept=([unpushed]=0 [unknown]=0 [refused]=0)
      shopt -s nullglob
      for e in "$d"/.sessions/* "$d"/.sessions-store/*; do
        n=''${e##*/} kind=tree
        [[ $e == "$d"/.sessions-store/* ]] && kind=store
        # the current layout's docks
        [[ $kind == store || $n != dock ]] || continue
        if ! valid "$n" || [[ -L $e || ! -d $e ]]; then
          jq -cn --arg e "$e" '{event: "refused", reason: "not a session directory", path: $e}'
          kept[refused]=$((kept[refused] + 1))
          continue
        fi
        if grep -qxF -- "$n" <<<"$gone"; then
          to=$d/.trash/legacy-$kind-$n-$stamp
          if mv -T --no-copy -- "$e" "$to"; then
            removed=$((removed + 1))
            jq -cn --arg k "$kind" --arg n "$n" --arg to "$to" '{event: "removed", kind: $k, dir: $n, trash: $to}'
          else
            rc=1
          fi
        elif grep -qxF -- "$n" <<<"$known"; then
          kept[unpushed]=$((kept[unpushed] + 1))
        else
          kept[unknown]=$((kept[unknown] + 1))
        fi
      done
      s=$d/.sessions-store
      if [[ -d $s && ! -L $s ]] && rmdir -- "$s" 2>/dev/null; then
        jq -cn --arg s "$s" '{event: "removed", kind: "store-dir", path: $s}'
      fi
      echo "$removed" > ${state}/removed || rc=1
      {
        printf 'homelab_exec_pool_legacy_sessions_removed_total %s\n' "$removed"
        for k in unpushed unknown refused; do
          printf 'homelab_exec_pool_legacy_sessions_kept{reason="%s"} %s\n' "$k" "''${kept[$k]}"
        done
      } > ${dir}/legacy-sessions.prom.tmp && mv ${dir}/legacy-sessions.prom.tmp ${dir}/legacy-sessions.prom || rc=1
      exit "$rc"
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && lib.elem "runner" cfg.roles) {
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${dir}" ];
    # before the first run: node-exporter counts a missing directory as a textfile scrape error
    systemd.tmpfiles.rules = [
      "d ${dir} 0755 root root -"
      "d ${state} 0700 root root -"
      "d ${listDir} 0700 exec_pool exec_pool -"
    ];
    systemd.services.exec-pool-legacy-sessions-list = {
      description = "List the sessions for exec-pool-legacy-sessions, as exec_pool";
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
    systemd.services.exec-pool-legacy-sessions = {
      description = "Move the old layout's session trees whose work is on the remote, or cancelled, into .trash";
      # a fresh list each run: the lister is a oneshot that does not stay active
      requires = [ "exec-pool-legacy-sessions-list.service" ];
      after = [ "exec-pool-legacy-sessions-list.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe remover;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        NoNewPrivileges = true;
        # the renames out of the old store's 0700 directories and into root's 0700 .trash
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
    systemd.timers.exec-pool-legacy-sessions = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
