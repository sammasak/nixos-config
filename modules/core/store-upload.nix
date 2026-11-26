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
        { ${pkgs.util-linux}/bin/flock 9 && for p in $OUT_PATHS; do echo "$p"; done >>${queue}; } 9>>${queue}.lock 2>/dev/null || true
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
      # shared: the retention pass would take the roots below for dangling while their paths are on the way
      exec 8<${state}/retain.lock
      flock -s 8
      # an unreachable cache is the sender's retry; anything it then lacks (collected since) is dropped
      nix store info --store "$url" >/dev/null
      # rooted before the copy, so a collection starting during it keeps them; a failed path loses its root again.
      # A collection already past its root scan can still take a path that was present, a window of milliseconds.
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
      pkgs.util-linux
      config.programs.ssh.package
    ];
    text = ''
      s=${queue}.sending
      (
        flock 9
        if [ -e ${queue} ]; then
          cat ${queue} >>"$s"
          rm ${queue}
        fi
      ) 9>>${queue}.lock
      n=0
      if [ -s "$s" ]; then
        sort -u -o "$s" "$s"
        n=$(wc -l <"$s")
      fi
      { read -r sent last <${state}/sent; } 2>/dev/null || { sent=0 last=0; }
      if [ "$n" -gt 0 ]; then
        if ssh -T -i /etc/ssh/ssh_host_ed25519_key -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
          -o ServerAliveInterval=20 store-upload@${hosts.${receiver}.address} <"$s"; then
          sent=$((sent + n))
          last=$(date +%s)
          n=0
          rm "$s"
          echo "$sent $last" >${state}/sent
        else
          echo "store-upload: ${receiver} did not take $n paths; they wait for the next try"
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
    '';
  };

  # drops roots older than keepDays and dangling ones, then the oldest quarter until the closures they keep fit capBytes
  retain = pkgs.writeShellApplication {
    name = "store-upload-retain";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.util-linux
    ];
    text = ''
      exec 8<${state}/retain.lock
      flock 8
      find ${roots} -mindepth 2 -maxdepth 2 -type l \( -mtime +${toString keepDays} -o -xtype l \) -delete
      # the links of host $1, or of every host for "", oldest first
      links() {
        local d=2
        [ -z "$1" ] || d=1
        find ${roots}/"$1" -mindepth "$d" -maxdepth "$d" -type l -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-
      }
      # the NAR bytes of the union of the closures of the links on stdin
      closure() { xargs -r readlink | xargs -r nix path-info -r -s | awk '{ s += $2 } END { print s + 0 }'; }
      total=$(links "" | closure)
      while [ "$total" -gt ${toString capBytes} ]; do
        mapfile -t all < <(links "")
        drop=$(((''${#all[@]} + 3) / 4))
        rm -f "''${all[@]:0:drop}"
        total=$(links "" | closure)
      done
      {
        echo "# HELP store_upload_roots Built outputs ${host} keeps under gcroots, per host that built them."
        echo "# TYPE store_upload_roots gauge"
        echo "# HELP store_upload_roots_bytes NAR bytes of the closures of those outputs; a path two hosts share counts under each."
        echo "# TYPE store_upload_roots_bytes gauge"
        echo "# HELP store_upload_roots_closure_bytes NAR bytes of the closures every kept output holds, against the cap."
        echo "# TYPE store_upload_roots_closure_bytes gauge"
        echo "# HELP store_upload_received_paths_total Paths a sender's upload asked for, by result."
        echo "# TYPE store_upload_received_paths_total counter"
        echo "store_upload_roots_cap_bytes ${toString capBytes}"
        echo "store_upload_roots_closure_bytes $total"
        for h in ${lib.concatStringsSep " " ([ host ] ++ senders)}; do
          echo "store_upload_roots{host=\"$h\"} $(links "$h" | wc -l)"
          echo "store_upload_roots_bytes{host=\"$h\"} $(links "$h" | closure)"
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
        # the path unit starts it again after every send while a build burst refills the queue: systemd's default
        # limit (5 starts in 10 s) would refuse it and fail store-upload.path with unit-start-limit-hit
        startLimitIntervalSec = 0;
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
        "f ${state}/retain.lock 0644 store-upload store-upload -"
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
