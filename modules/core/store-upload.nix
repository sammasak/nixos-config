# What a sleeping store cache (sam.fleet sleeps) builds survives its power-off: Nix's post-build-hook queues each built
# output, and the host hands the queue to acer, which pulls the paths from its harmonia and keeps them under gcroots.
# acer's hook roots its own builds the same way. Retention is by age and a size cap; both sides write gauges.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.sam.fleet) hosts;
  host = config.networking.hostName;
  receiver = "acer-swift";
  port = 5000;
  state = "/var/lib/store-upload";
  queue = "${state}/queue";
  roots = "/nix/var/nix/gcroots/store-upload";
  textfile = "/run/node-exporter-textfile/store-upload.prom";
  keepDays = 14;
  capBytes = 100 * 1024 * 1024 * 1024;
  cache = config.sam.storeCache.enable;
  sleeps = (hosts.${host} or { sleeps = false; }).sleeps;
  uploader = cache && sleeps;
  receiving = cache && host == receiver;
  # the sleeping hosts that serve a store cache; acer trusts their cache keys for the pulls alone
  senders = lib.filter (n: hosts.${n}.sleeps) (lib.attrNames config.sam.storeCache.keys);
  storePath = "/nix/store/[0-9a-z]{32}-[^/[:space:]]+";

  # a failing post-build-hook fails the build it follows, and the daemon waits for it: append and never exit non-zero
  hook = pkgs.writeShellScript "store-upload-hook" (
    if uploader then
      ''
        for p in $OUT_PATHS; do echo "$p"; done >>${queue} 2>/dev/null || true
      ''
    else
      ''
        for p in $OUT_PATHS; do ${pkgs.coreutils}/bin/ln -sfn "$p" ${roots}/${host}/"''${p#/nix/store/}" 2>/dev/null; done
        exit 0
      ''
  );

  # the forced command of a sender's key on acer: store paths on stdin, pulled from that sender's cache
  receive = pkgs.writeShellApplication {
    name = "store-upload-receive";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.util-linux
    ];
    text = ''
      from=$1
      url=$2
      dir=${roots}/$from
      export XDG_CACHE_HOME=${state}/cache
      paths=$(head -n 100000 | grep -xE '${storePath}' | sort -u) || true
      [ -n "$paths" ] || exit 0
      # an unreachable cache is the sender's retry; anything it then lacks (collected since) is dropped
      nix store info --store "$url" >/dev/null
      # rooted before the copy, so a collection during it cannot take them; a failed path loses its root again
      for p in $paths; do ln -sfn "$p" "$dir/''${p#/nix/store/}"; done
      ok=0
      failed=0
      # shellcheck disable=SC2086 # one store path per word
      if nix copy --from "$url" $paths; then
        ok=$(wc -l <<<"$paths")
      else
        for p in $paths; do
          if nix copy --from "$url" "$p"; then ok=$((ok + 1)); else
            failed=$((failed + 1))
            rm -f "$dir/''${p#/nix/store/}"
          fi
        done
      fi
      (
        flock 9
        { read -r c f <"${state}/$from.counts"; } 2>/dev/null || { c=0 f=0; }
        echo "$((c + ok)) $((f + failed))" >"${state}/$from.counts"
      ) 9>"${state}/counts.lock"
      echo "store-upload: $from: copied $ok, failed $failed"
    '';
  };

  send = pkgs.writeShellApplication {
    name = "store-upload-send";
    runtimeInputs = [
      pkgs.coreutils
      config.programs.ssh.package
    ];
    text = ''
      s=${queue}.sending
      if [ -e ${queue} ]; then
        mv ${queue} ${queue}.taken
        cat ${queue}.taken >>"$s"
        rm ${queue}.taken
      fi
      n=0
      if [ -s "$s" ]; then
        sort -u -o "$s" "$s"
        n=$(wc -l <"$s")
      fi
      { read -r sent last <${state}/sent; } 2>/dev/null || { sent=0 last=0; }
      rc=0
      if [ "$n" -gt 0 ]; then
        if ssh -T -i /etc/ssh/ssh_host_ed25519_key -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
          -o ServerAliveInterval=20 store-upload@${hosts.${receiver}.address} <"$s"; then
          sent=$((sent + n))
          last=$(date +%s)
          n=0
          rm "$s"
          echo "$sent $last" >${state}/sent
        else
          rc=1
        fi
      fi
      cat >${textfile}.new <<EOF
      # HELP store_upload_queue_paths Built paths waiting for the upload to ${receiver}.
      # TYPE store_upload_queue_paths gauge
      store_upload_queue_paths $n
      # HELP store_upload_sent_paths_total Built paths ${receiver} took.
      # TYPE store_upload_sent_paths_total counter
      store_upload_sent_paths_total $sent
      # HELP store_upload_last_success_timestamp_seconds When ${receiver} last took a batch, 0 never.
      # TYPE store_upload_last_success_timestamp_seconds gauge
      store_upload_last_success_timestamp_seconds $last
      EOF
      mv ${textfile}.new ${textfile}
      exit "$rc"
    '';
  };

  # drops roots older than keepDays and dangling ones, then the oldest until the rooted outputs fit capBytes
  retain = pkgs.writeShellApplication {
    name = "store-upload-retain";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
    ];
    text = ''
      find ${roots} -mindepth 2 -maxdepth 2 -type l \( -mtime +${toString keepDays} -o -xtype l \) -delete
      mapfile -t links < <(find ${roots} -mindepth 2 -maxdepth 2 -type l -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
      declare -A size=()
      if [ ''${#links[@]} -gt 0 ]; then
        while read -r p s; do size[$p]=$s; done < <(for l in "''${links[@]}"; do readlink "$l"; done | sort -u | xargs nix path-info -s)
      fi
      declare -A count=() bytes=()
      total=0
      for l in "''${links[@]}"; do
        h=$(basename "$(dirname "$l")")
        s=''${size[$(readlink "$l")]:-0}
        if [ $((total + s)) -gt ${toString capBytes} ]; then rm -f "$l"; continue; fi
        total=$((total + s))
        count[$h]=$((''${count[$h]:-0} + 1))
        bytes[$h]=$((''${bytes[$h]:-0} + s))
      done
      {
        echo "# HELP store_upload_roots Built outputs ${host} keeps under gcroots, per host that built them."
        echo "# TYPE store_upload_roots gauge"
        echo "# HELP store_upload_roots_bytes NAR bytes of those outputs, closures not counted."
        echo "# TYPE store_upload_roots_bytes gauge"
        echo "# HELP store_upload_received_paths_total Paths a sender's upload asked for, by result."
        echo "# TYPE store_upload_received_paths_total counter"
        echo "store_upload_roots_cap_bytes ${toString capBytes}"
        for h in ${lib.concatStringsSep " " ([ host ] ++ senders)}; do
          echo "store_upload_roots{host=\"$h\"} ''${count[$h]:-0}"
          echo "store_upload_roots_bytes{host=\"$h\"} ''${bytes[$h]:-0}"
        done
        for h in ${lib.concatStringsSep " " senders}; do
          { read -r c f <"${state}/$h.counts"; } 2>/dev/null || { c=0 f=0; }
          echo "store_upload_received_paths_total{host=\"$h\",result=\"copied\"} $c"
          echo "store_upload_received_paths_total{host=\"$h\",result=\"failed\"} $f"
        done
      } >${textfile}.new
      mv ${textfile}.new ${textfile}
    '';
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf (uploader || receiving) {
      nix.settings.post-build-hook = hook;
      assertions = [
        {
          assertion = !hosts.${receiver}.sleeps;
          message = "modules/core/store-upload.nix: ${receiver} takes the sleeping hosts' builds, so it must not sleep (modules/core/fleet.nix).";
        }
      ];
    })
    (lib.mkIf uploader {
      systemd.tmpfiles.rules = [ "d ${state} 0700 root root -" ];
      systemd.services.store-upload = {
        description = "Hand this host's built paths to ${receiver}'s store";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe send;
          Nice = 10;
        };
      };
      systemd.paths.store-upload = {
        wantedBy = [ "paths.target" ];
        pathConfig.PathExists = queue;
      };
      # the retry while ${receiver} is down, and the first try after a boot
      systemd.timers.store-upload = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitInactiveSec = "10min";
        };
      };
    })
    (lib.mkIf receiving {
      nix.settings = {
        trusted-public-keys = map (n: config.sam.storeCache.keys.${n}) senders;
        allowed-users = [ "store-upload" ];
      };
      users.groups.store-upload = { };
      users.users.store-upload = {
        isSystemUser = true;
        group = "store-upload";
        home = state;
        createHome = true;
        shell = pkgs.bash;
        # each sender logs in with its ssh host key, from its own address, and runs nothing but the pull from itself
        openssh.authorizedKeys.keys = map (
          n:
          ''restrict,from="${hosts.${n}.address}",command="${lib.getExe receive} ${n} http://${hosts.${n}.address}:${toString port}" ${
            config.programs.ssh.knownHosts.${n}.publicKey
          }''
        ) senders;
      };
      services.openssh.settings.AllowUsers = [ "store-upload" ];
      systemd.tmpfiles.rules = [
        "d ${roots} 0755 store-upload store-upload -"
        "d ${roots}/${host} 0755 root root -"
      ]
      ++ map (n: "d ${roots}/${n} 0755 store-upload store-upload -") senders;
      systemd.services.store-upload-retain = {
        description = "Expire the kept built outputs by age and size, and count them";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe retain;
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
      systemd.timers.store-upload-retain = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "1h";
        };
      };
    })
  ];
}
