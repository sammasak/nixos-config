# Declared developer environments, free of this fleet (modules/workers/default.nix is its adapter): each
# `services.devEnvironments.instances.<name>` is a stock `containers.<name>` with an ephemeral root, a persistent home
# and an agent reached over ssh; an instance moved to `retired` has its home trashed for a week.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.devEnvironments;
  user = cfg.user;
  hostUser = config.users.users.${user} or { };
  home = hostUser.home or "/home/${user}";
  group = hostUser.group or "users";
  hostName = config.networking.hostName;
  creds = "/var/lib/host-credentials";
  clientKey = "${home}/.ssh/id_ed25519";
  slice = "environments";
  # the dynamic shipper's textfile: node-exporter cannot traverse /run/private, so a fixed group writes here. A
  # shipper subverted by a guest's bytes could add .prom files the host's scrape then reads; it could not before
  recordsMetrics = "/run/dev-env-records-metrics";
  workLocks = "/run/work-locks";
  # a parked or docked session's devenv roots: it is no instance, so it has no per-container dir
  sessionRoots = "/nix/var/nix/gcroots/dev-env-sessions";
  sessionMetrics = "/run/dev-env-sessions-metrics";

  multipliers = {
    "" = 1;
    K = 1024;
    M = 1048576;
    G = 1073741824;
    T = 1099511627776;
  };
  parseSize =
    s:
    let
      m = builtins.match "([0-9]+)([KMGT]?)" s;
    in
    lib.toInt (lib.head m) * multipliers.${lib.elemAt m 1};
  size = types.coercedTo (types.strMatching "[1-9][0-9]*[KMGT]?") parseSize types.ints.positive;
  showSize = b: "${toString (b / 1048576)}M";
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  cidr = types.strMatching "${octet}\\.${octet}\\.${octet}\\.${octet}/([0-9]|[12][0-9]|3[0-2])";
  nameType = types.strMatching "[a-z][a-z0-9-]{0,10}";
  keyAlias = "environments.${cfg.prefix}";
  # 0x70000000, above nspawn's `pick` range (0x80000 to 0x6fff0000): instance index i (1 to 254) owns the 65536 ids
  # from uidBase + i * 65536, below 2^31
  uidBase = 1879048192;
  baseOf = w: uidBase + w.index * 65536;
  gid = config.users.groups.${group}.gid;
  # Under rootInGuest the writable binds are not id-mapped: on disk they belong to the guest user's mapped ids, so guest
  # root writes as baseOf w, never as a host user; its own host key and alias keep it from posing as another instance.
  owner =
    w:
    if w.rootInGuest then
      {
        u = toString (baseOf w + cfg.uid);
        g = toString (baseOf w + gid);
      }
    else
      {
        u = user;
        g = group;
      };
  # The block an instance's dirs were made in (0: the host's ids) is written once, with them; an instance whose
  # rootInGuest changed would start on a home of the other block, so it does not start. Nothing is chowned.
  idCheck = pkgs.writeShellScript "dev-env-id-check" ''
    have=$(cat "$1/.id-base" 2>/dev/null || true)
    [[ ''${have:-0} == "$2" ]] && exit 0
    echo "''${1##*/}: rootInGuest was toggled on an existing environment; retire it (or declare it under a new name) so it starts from a fresh home" >&2
    exit 1
  '';
  # Retire and reset share these (with $d the state dir, $n the name), so a reset leaves exactly what a retire plus a
  # new declaration would.
  trashOne = ''
    # a rename on the state dir's filesystem, never a copy, and never through a link
    if [[ ! -L $d/$n && -d $d/$n ]]; then
      ${lib.optionalString (cfg.records != null) ''
        # its last records first, bounded: Loki down never holds a retire, a reset or an activation
        ${pkgs.coreutils}/bin/timeout 30 ${config.systemd.package}/bin/systemctl start "dev-env-records@$n.service" || true
      ''}
      mv -T --no-copy "$d/$n" "$d/.trash/$n-$(date +%Y%m%d-%H%M%S)"
    fi
    rm -rf --one-file-system "/nix/var/nix/profiles/per-container/$n" "/nix/var/nix/gcroots/per-container/$n"
  '';
  # Aged by when it was trashed (the rename sets the entry's ctime), not by tmpfiles: that ages each file by its own
  # times, so a retired home's old files would go at its next clean. A .trash that is a link or another mount would
  # put a live home in reach: refused. A second argument, the recorder (platform-record), gets one trash-sweep record
  # of counts alone (entries seen, deleted, the bytes of their files and links), never a name; the activation passes
  # none, so it never waits on Loki.
  trashSweep = pkgs.writeShellApplication {
    name = "dev-env-trash-sweep";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
    ];
    text = ''
      t=$1/.trash
      recorder=''${2:-}
      [[ -e $t || -L $t ]] || exit 0
      if [[ -L $t || ! -d $t || $(stat -c %d "$1") != "$(stat -c %d "$t")" ]]; then
        echo "dev-env-trash-sweep: $t is a link, not a directory or on another filesystem than $1; not swept" >&2
        [[ -z $recorder ]] || "$recorder" trash-sweep seen=0 deleted=0 bytes=0 result=refused
        exit 1
      fi
      # a find that fails (an unreadable entry) marks the run failed: under set -e it would end it before the record
      deleted=0 bytes=0 result=ok
      seen=$(find -P "$t" -xdev -mindepth 1 -maxdepth 1 -printf . | wc -c) || result=failed
      # read whole, so find's own exit status is seen: a process substitution's is otherwise lost
      mapfile -d "" -t old < <(find -P "$t" -xdev -mindepth 1 -maxdepth 1 -cmin +10080 -print0)
      wait "$!" || result=failed
      for e in "''${old[@]}"; do
        size=$(find -P "$e" -xdev ! -type d -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }') || result=failed
        if rm -rf --one-file-system -- "$e"; then
          deleted=$((deleted + 1)) bytes=$((bytes + size))
        else
          result=failed
        fi
      done
      [[ -z $recorder ]] || "$recorder" trash-sweep seen="$seen" deleted="$deleted" bytes="$bytes" result="$result"
      [[ $result == ok ]]
    '';
  };
  # A dynamic user with CAP_DAC_READ_SEARCH alone: it reads every home whoever owns it, writes only its
  # StateDirectory (and the timer's unit recordsMetrics) and reaches only Loki. The timer's unit and the per-instance one share the user, so the state.
  recordsUnit = names: timeout: {
    Type = "oneshot";
    ExecStart = lib.escapeShellArgs (
      [
        (lib.getExe pkgs.python3)
        "-I"
        "${../../scripts/guest-records.py}"
        "--state-dir"
        cfg.stateDir
        "--prefix"
        cfg.prefix
        "--url"
        "${cfg.records.url}/loki/api/v1/push"
        "--kinds"
        (lib.concatStringsSep "," cfg.records.kinds)
        "--fleet"
        (lib.concatStringsSep "," cfg.records.fleet)
      ]
      ++ names
    );
    TimeoutStartSec = timeout;
    DynamicUser = true;
    User = "dev-env-records";
    StateDirectory = "dev-env-records";
    StateDirectoryMode = "0700";
    AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    IPAddressDeny = "any";
    IPAddressAllow = cfg.records.address;
    MemoryMax = "128M";
  };
  # the shipper's sandbox, pushing usage instead of the spools: cgroup files and the containers' confs are world-readable
  usageUnit =
    names:
    let
      u = recordsUnit names "25s";
    in
    u
    // {
      ExecStart =
        u.ExecStart
        + " "
        + lib.escapeShellArgs [
          "--usage"
          "--cgroup"
          "/sys/fs/cgroup/${slice}.slice"
          "--containers"
          "/etc/nixos-containers"
        ];
    };
  prepareDirs = ''
    install -d -m 0711 "$d"
    install -d -m 0700 -o ${user} -g ${group} "$d/.nix-cache"
    [[ -e $d/ssh_host_ed25519_key ]] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f "$d/ssh_host_ed25519_key"
    echo "${keyAlias} $(cut -d' ' -f1,2 "$d/ssh_host_ed25519_key.pub")" > "$d/known_hosts"
    chmod 0644 "$d/known_hosts"
    ${lib.concatMapStrings (
      w:
      let
        o = owner w;
      in
      ''
        install -d -m 0700 "$d/${w.name}"
        if [[ ! -d $d/${w.name}/home ]]; then
          echo ${
            toString (if w.rootInGuest then baseOf w else 0)
          } > "$d/${w.name}/.id-base.new" && chmod 0644 "$d/${w.name}/.id-base.new" && mv -f "$d/${w.name}/.id-base.new" "$d/${w.name}/.id-base"
          install -d -m 0700 -o ${o.u} -g ${o.g} "$d/${w.name}/home"
        fi
        # mkdir and chown -h: the guest owns ~/.cache, and install -d follows a symlink there and chmods and chowns its target
        mkdir -m 0755 "$d/${w.name}/home/.cache" 2>/dev/null && chown -h ${o.u}:${o.g} "$d/${w.name}/home/.cache" || true
        [[ -d $d/${w.name}/eval-cache ]] || install -d -m 0700 -o ${o.u} -g ${o.g} "$d/${w.name}/eval-cache"
      ''
      # root's at every level, so the guest cannot swap the dir its tree is renamed into
      + lib.optionalString w.sessionDock ''
        install -d -m 0711 "$d/.sessions"
        install -d -m 0755 "$d/.sessions/dock" "$d/.sessions/dock/${w.name}"
      ''
      + lib.optionalString w.rootInGuest ''
        [[ -d $d/${w.name}/nix-cache ]] || install -d -m 0700 -o ${o.u} -g ${o.g} "$d/${w.name}/nix-cache"
        [[ -e $d/${w.name}/ssh_host_ed25519_key ]] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f "$d/${w.name}/ssh_host_ed25519_key"
        chown ${toString (baseOf w)}:${toString (baseOf w)} "$d/${w.name}/ssh_host_ed25519_key"
        echo "${aliasOf w} $(cut -d' ' -f1,2 "$d/${w.name}/ssh_host_ed25519_key.pub")" >> "$d/known_hosts"
      ''
    ) instances}
  '';
  # its own process, so the ERR trap marks any failed step: inside an if condition bash would ignore it
  resetSteps = pkgs.writeShellScript "dev-env-reset-steps" ''
    rc=0
    trap rc=1 ERR
    d=${lib.escapeShellArg cfg.stateDir} n=$1
    ${trashOne}
    [[ ! -e $d/$n ]] || rc=1
    ${prepareDirs}
    exit "$rc"
  '';
  aliasOf = w: if w.rootInGuest then "${w.name}.${keyAlias}" else keyAlias;
  hostKeyOf =
    w:
    if w.rootInGuest then
      "${cfg.stateDir}/${w.name}/ssh_host_ed25519_key"
    else
      "${cfg.stateDir}/ssh_host_ed25519_key";
  # a fish single-quoted word reads \\ and \' as escapes, a POSIX one does not
  escape =
    if cfg.shell == "fish" then
      s: "'" + lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] s + "'"
    else
      lib.escapeShellArg;

  # From the name alone, so declaring or removing another instance never renumbers (and restarts) this one.
  indexOf =
    name: lib.mod (lib.fromHexString (lib.substring 0 4 (builtins.hashString "sha256" name))) 254 + 1;

  instances = lib.mapAttrsToList (
    _: i:
    i
    // rec {
      index = indexOf i.name;
      hostName = "${cfg.prefix}-${i.name}";
      hostAddress = "10.233.${toString index}.1";
      address = "10.233.${toString index}.2";
      agentDef = cfg.agents.${i.agent} or null;
    }
  ) cfg.instances;

  # a paused instance is declared nowhere but here: its units go as a retired one's do, and nothing removes what it holds
  running = lib.filter (w: !w.paused) instances;
  reservedMem = lib.foldl' (s: w: s + w.memory.reserved) 0 running;

  # The credential proxy: a socket directory per instance (its identity), secrets as unit credentials, never in the store.
  egressDir = "/run/dev-env-egress";
  egressAll = lib.mapAttrsToList (name: s: s // { inherit name; }) cfg.egress;
  egressOf = w: lib.filter (s: s.for w) egressAll;
  # the host credentials bound into an instance: the guest links exactly these (devEnvironment.credentials)
  boundOf =
    w: lib.filterAttrs (n: _: w.credentials == null || lib.elem n w.credentials) cfg.credentials;
  egressed = lib.filter (w: egressOf w != [ ]) running;
  egressUsed = lib.filter (s: lib.any s.for instances) egressAll;
  egressSecrets = lib.concatMap (
    s:
    lib.mapAttrsToList (n: path: {
      inherit n path;
      inherit (s) missing;
    }) s.secrets
  ) egressUsed;
  caddyfile = pkgs.writeText "dev-env-egress.Caddyfile" (
    ''
      {
        admin off
        auto_https off
      }
    ''
    + lib.concatMapStrings (
      w:
      lib.concatMapStrings (s: ''
        http:// {
          bind unix/${egressDir}/${w.name}/${s.name}.sock
          log ${s.name}-${w.name}
          ${s.site w}
        }
      '') (egressOf w)
    ) egressed
  );

  argv =
    w: resume:
    w.agentDef.command
    ++ lib.optionals resume w.agentDef.resumeArgs
    ++ lib.optionals (w.model != null) [
      "--model"
      w.model
    ];
  # The agent's command line as a file the guest's login shell sources: no user string is ever quoted for ssh.
  agentScript =
    w: resume:
    pkgs.writeText "${w.hostName}-${if resume then "continue" else "start"}.${cfg.shell}" ''
      ${lib.concatMapStringsSep " " escape (argv w resume)}
      exec ${cfg.shell} -il
    '';
  remote =
    w: resume:
    lib.escapeShellArg "${cfg.shell} -il -c ${lib.escapeShellArg "source ${agentScript w resume}"}";
  resumable =
    w:
    pkgs.writeShellApplication {
      name = "${w.hostName}-resumable";
      text = ''
        shopt -s nullglob
        found=("$HOME"/${w.agentDef.resumeWhen})
        (( ''${#found[@]} > 0 ))
      '';
    };

  hostOptions = w: {
    HostKeyAlias = aliasOf w;
    UserKnownHostsFile = "${cfg.stateDir}/known_hosts";
    StrictHostKeyChecking = "yes";
    LogLevel = "ERROR";
  };
  ssh =
    w: opts:
    "ssh ${opts} ${
      lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "-o ${k}=${v}") (hostOptions w))
    } ${user}@${w.address}";
  # The instance's one entry point on the host: a session surface (or a person) runs `attach` in a terminal.
  ctl =
    w:
    pkgs.writeShellApplication {
      name = "${cfg.unitPrefix}-${w.name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssh
      ];
      text = ''
        case ''${1-} in
          wait)
            for _ in $(seq 300); do
              if st=$(${ssh w "-o BatchMode=yes -o ConnectTimeout=2"} systemctl show --property=LoadState,ActiveState home-manager-${user}.service 2>/dev/null); then
                case $st in
                  *LoadState=not-found*|*ActiveState=active*) exit 0 ;;
                  *ActiveState=failed*) echo "home-manager-${user}.service failed in ${w.name}" >&2; exit 2 ;;
                esac
              fi
              sleep "''${WORKER_WAIT_TICK-1}" # overridable so the eval test does not wait 300 s
            done
            case ''${st-} in *ActiveState=activating*) echo "home-manager-${user}.service is still activating in ${w.name}" >&2 ;; esac
            exit 1 ;;
          resumable)
            ${
              if w.agentDef == null || w.agentDef.resumeWhen == null then
                "exit 1"
              else
                "${ssh w "-o BatchMode=yes"} ${lib.getExe (resumable w)} 2>/dev/null"
            } ;;
          attach)
            ${
              if w.agentDef == null then
                ''
                  exec ${ssh w "-tt -o ConnectTimeout=10 -o ServerAliveInterval=30"}
                ''
              else
                ''
                  cmd=${remote w false}
                  if [[ ''${2-} == continue ]]; then cmd=${remote w true}; fi
                  # Herdr detects the agent from the pane's foreground argv[0], so ssh is named after it
                  exec -a ${w.agent} ${ssh w "-tt -o ConnectTimeout=10 -o ServerAliveInterval=30"} "$cmd"
                ''
            } ;;
          *) echo "usage: ${cfg.unitPrefix}-${w.name} wait|resumable|attach [fresh|continue]" >&2; exit 2 ;;
        esac
      '';
    };

  # A guest's nix asks its substituters itself as well as through the daemon (devenv does): one it cannot reach
  # costs every such command the connect timeout, so those at a LAN address stay reachable.
  lanCaches = lib.filter (m: m != null) (
    map (builtins.match "http://([0-9.]+):([0-9]+)/?") config.nix.settings.substituters
  );

  binds =
    w:
    {
      "${home}" = {
        hostPath = "${cfg.stateDir}/${w.name}/home";
        isReadOnly = false;
      };
      # Nix's per-user fetcher and tarball caches, one per host: a fresh home re-downloads and re-unpacks every flake
      # input the store already holds (31 s against 7 s for the first devenv shell on acer).
      # rootInGuest: its own, so its root cannot leave entries a neighbour cannot use
      "${home}/.cache/nix" = {
        hostPath =
          if w.rootInGuest then "${cfg.stateDir}/${w.name}/nix-cache" else "${cfg.stateDir}/.nix-cache";
        isReadOnly = false;
      };
      # Not the evaluation cache in it: its rows are unsigned, so a neighbour could plant the derivation another
      # environment then builds. The name is Nix's: workers-eval-test fails when the guest's Nix names it otherwise.
      "${home}/.cache/nix/eval-cache-v6" = {
        hostPath = "${cfg.stateDir}/${w.name}/eval-cache";
        isReadOnly = false;
      };
      # read-only, so a guest cannot create a lock file there: work-locks.nix makes them on the host
      ${workLocks} = {
        hostPath = workLocks;
        isReadOnly = true;
      };
      "${creds}/ssh_host_ed25519_key" = {
        hostPath = hostKeyOf w;
        isReadOnly = true;
      };
      "${creds}/${baseNameOf clientKey}.pub" = {
        hostPath = "${clientKey}.pub";
        isReadOnly = true;
      };
    }
    // lib.mapAttrs' (
      n: src:
      lib.nameValuePair "${creds}/${n}" {
        hostPath = src;
        isReadOnly = true;
      }
    ) (boundOf w)
    // lib.optionalAttrs (egressOf w != [ ]) {
      "/run/egress" = {
        hostPath = "${egressDir}/${w.name}";
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs w.sessionDock {
      "/session" = {
        hostPath = "${cfg.stateDir}/.sessions/dock/${w.name}";
        isReadOnly = false;
      };
    };

  guest = w: { ... }: {
    imports = cfg.guestModules ++ map (s: s.guest.config) (egressOf w);
    _module.args.devEnvironment = {
      inherit (w) name hostName address;
      credentials = lib.attrNames (boundOf w);
    };
    # the host user's uid: its credential files and nix daemon identity
    # sudo is root of this namespace only; subordinate ids must fit the guest's 65536, or rootless podman fails
    users.users.${user} = {
      isNormalUser = true;
      inherit (cfg) uid;
    }
    // lib.optionalAttrs w.rootInGuest {
      extraGroups = [ "wheel" ];
      autoSubUidGidRange = false;
      subUidRanges = [
        {
          startUid = 10000;
          count = 55536;
        }
      ];
      subGidRanges = [
        {
          startGid = 10000;
          count = 55536;
        }
      ];
    };
    security.sudo.wheelNeedsPassword = lib.mkIf w.rootInGuest false;
    networking.hostName = w.hostName;
    networking.useHostResolvConf = lib.mkIf (cfg.nameservers != [ ]) false;
    networking.nameservers = cfg.nameservers;
    programs.fish.enable = lib.mkIf (cfg.shell == "fish") true;

    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      # one key per host, generated at activation under stateDir and bound read-only: never the host's own sshd key
      hostKeys = [
        {
          path = "${creds}/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      authorizedKeysFiles = [ "${creds}/${baseNameOf clientKey}.pub" ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ user ];
      };
    };

    # the default NIX_PATH names root's channels, which a guest has none of: every nix command warned on stderr
    nix.channel.enable = false;
    nix.nixPath = [ "nixpkgs=${pkgs.path}" ];
    nix.registry.nixpkgs.to = {
      type = "path";
      path = pkgs.path;
    };

    # The guest's nix is a client of the host's daemon, which takes a client's substituters (when it trusts each of
    # them), max-jobs and cores over its own: the guest's defaults skipped the fleet's store caches and lifted the
    # host's build bounds. An empty flake-registry fetched the global one on every cold cache.
    # mkForce: the guest's own defaults would list again what the host's already holds
    nix.settings = {
      flake-registry = "";
      inherit (config.nix.settings) max-jobs cores;
      substituters = lib.mkForce config.nix.settings.substituters;
      trusted-public-keys = lib.mkForce config.nix.settings.trusted-public-keys;
    }
    # the host's two answers to a dead store cache, where it sets them (store-cache.nix)
    // lib.intersectAttrs {
      connect-timeout = null;
      fallback = null;
    } config.nix.settings;

    # lean: the boot is the start latency
    documentation.enable = false;
    # watches no cgroup in a guest: the kernel kills at the pool limit
    systemd.oomd.enable = false;
    services.udisks2.enable = false;
    xdg.sounds.enable = false;

    # the guest holds placeholders, not the tokens: the proxy adds the login to each call
    environment.variables = lib.mkMerge (map (s: s.guest.env) (egressOf w));
    # platform-record keeps its records in the spool the host ships: a push of its own could never reach Loki.
    # sessionVariables: also the user manager's, so a guest user unit that records gets it too
    environment.sessionVariables = lib.mkIf (cfg.records != null) { PLATFORM_RECORD_SHIPPER = "host"; };
    systemd.sockets = lib.listToAttrs (
      map (
        s:
        lib.nameValuePair "${s.name}-egress" {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString s.port}" ];
        }
      ) (egressOf w)
    );
    systemd.services =
      lib.listToAttrs (
        map (
          s:
          lib.nameValuePair "${s.name}-egress" {
            serviceConfig = {
              User = user;
              ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${s.socket}";
            };
          }
        ) (egressOf w)
      )
      # At the pool limit the kernel kills the largest process in the whole slice: a gate's builds run as many
      # mid-sized ones, an agent as one big one. Every build forks from the daemon and inherits this, so it goes before
      # a session (0) unless the session outgrows it by half the pool. Not 1000: a runaway in a session would then
      # take every neighbour's builds first.
      // {
        nix-daemon.serviceConfig.OOMScoreAdjust = 500;
      };

    # the guest's cgroup files read max: the host's limits, read from the units that set them. Shell key=value,
    # so a job sources it (`. /etc/dev-environment`) or greps it without a parser; sizes in bytes.
    environment.etc."dev-environment".text =
      let
        unit = config.systemd.services."container@${w.name}".serviceConfig;
      in
      ''
        memory_reserved=${toString unit.MemoryMin}
        pool_memory=${toString config.systemd.slices.${slice}.sliceConfig.MemoryMax}
        pool_swap=${toString config.systemd.slices.${slice}.sliceConfig.MemorySwapMax}
        cpu_weight=${toString unit.CPUWeight}
        nix_max_jobs=${toString config.nix.settings.max-jobs}
        nix_cores=${toString config.nix.settings.cores}
      '';
  };

  egressModule = { name, ... }: {
    options = {
      for = mkOption {
        type = types.functionTo types.bool;
        description = "Which instances (the argument) get it.";
      };
      site = mkOption {
        type = types.functionTo types.lines;
        description = "The instance's Caddy site, after its bind and log.";
      };
      port = mkOption {
        type = types.port;
        description = "The guest's loopback port forwarded to the socket.";
      };
      socket = mkOption {
        type = types.str;
        default = "/run/egress/${name}.sock";
        readOnly = true;
        description = "The socket in the guest.";
      };
      secrets = mkOption {
        type = types.attrsOf (types.nullOr types.externalPath);
        default = { };
        description = "Host files loaded as the proxy's credentials, under paths.egress.credentials.";
      };
      missing = mkOption {
        type = types.str;
        description = "The assertion message when one of secrets is null.";
      };
      prepare = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "ExecStartPre commands; paths.egress.private is theirs and Caddy's.";
      };
      guest.env = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Environment of a guest that gets the service.";
      };
      guest.config = mkOption {
        type = types.deferredModule;
        default = { };
        description = "A NixOS module of a guest that gets the service.";
      };
    };
  };

  agentModule = {
    options = {
      command = mkOption {
        type = types.nonEmptyListOf types.nonEmptyStr;
        description = "argv started in the guest's login shell; it ends in that shell.";
      };
      resumeArgs = mkOption {
        type = types.listOf types.nonEmptyStr;
        default = [ ];
        description = "Appended when resumeWhen matches.";
      };
      resumeWhen = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9._*-][A-Za-z0-9._/*-]*");
        default = null;
        description = "A glob under the guest home; a match at start means there is a session to resume.";
      };
      readyText = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Text the agent draws once it takes input, for a session surface to wait on.";
      };
    };
  };

  instanceModule = { name, ... }: {
    options = {
      name = mkOption {
        type = nameType;
        default = name;
        readOnly = true;
        description = "At most 11 of [a-z0-9-], starting with a letter: the veth is ve-<name>.";
      };
      agent = mkOption {
        type = types.enum ([ "none" ] ++ lib.attrNames cfg.agents);
        default = "claude";
        description = "One of `agents`, or `none` for a shell.";
      };
      model = mkOption {
        type = types.nullOr (types.strMatching "[][A-Za-z0-9._:-]+");
        default = null;
        description = "The agent's model.";
      };
      prompt = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = "Sent by the session surface once the agent is ready, on a start with no session to resume.";
      };
      credentials = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [ "gh-hosts.yml" ];
        description = "Which of `credentials` this instance gets; null is all of them.";
      };
      paused = mkOption {
        type = types.bool;
        default = false;
        description = "Stopped, its container undeclared: its home, profiles and roots stay, its reserve is not counted, and flipping it back resumes the agent's session.";
      };
      scratch = mkOption {
        type = types.listOf (types.strMatching "[A-Za-z0-9_.-]+");
        default = [ ];
        description = "Directories directly under the home whose clones dev-env-reset@ trashes with the home without checking them for unpushed work.";
      };
      memory.reserved = mkOption {
        type = size;
        default = "2G";
        description = "MemoryMin: never reclaimed for a neighbour, and what the pool must fit. Above it an instance uses whatever the pool has idle.";
      };
      cpu.reserved = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Cores: CPUWeight 100 per core, a share under contention, all idle cores otherwise.";
      };
      sessionDock = mkOption {
        type = types.bool;
        default = false;
        description = "A read-write /session from the host's .sessions/dock/<name>, root's, where a session's home and work tree are moved in for one turn; adding it restarts the container once.";
      };
      rootInGuest = mkOption {
        type = types.bool;
        default = false;
        description = "Its own 65536 uids (guest root is an unprivileged host uid), its own host key, cache and sshd alias, and passwordless sudo. Only on a fresh instance: an existing one toggled refuses to start.";
      };
    };
  };
in
{
  imports = [ ../core/work-locks.nix ];

  options.services.devEnvironments = {
    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      example = {
        fix-ci = {
          model = "sonnet";
          prompt = "Fix the failing test and push a branch.";
        };
      };
      description = "Each runs, with a home that persists, while declared; once not, it is stopped and its home kept.";
    };
    retired = mkOption {
      type = types.listOf nameType;
      default = [ ];
      description = "Names whose home, profile and GC roots activation deletes, once their container is stopped.";
    };
    agents = mkOption {
      type = types.attrsOf (types.submodule agentModule);
      default = { };
      description = "Agents an instance can run; claude and codex are predefined.";
    };
    user = mkOption {
      type = types.passwdEntry types.str;
      description = "The host user owning the environments; the guest gets the same user and uid.";
    };
    uid = mkOption {
      type = types.ints.positive;
      description = "That user's uid; defaults to the declared one.";
    };
    shell = mkOption {
      type = types.enum [
        "bash"
        "fish"
      ];
      default = "bash";
      description = "The guest login shell the agent starts in.";
    };
    paths = mkOption {
      internal = true;
      readOnly = true;
      default = {
        inherit home creds clientKey;
        egress = {
          credentials = "/run/credentials/dev-env-egress.service";
          private = "/tmp";
        };
      };
      description = "The guest's home, where its host credentials are bound, the host user's ssh key, and the proxy's credentials and private directory (no guest sees it).";
    };
    alert = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Program run with a message when an instance's container fails, the pool's OOM killer fires or a disk runs low; null, no alerts.";
    };
    records = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              description = "Loki's base URL, http://<address>:<port>.";
            };
            address = mkOption {
              type = types.str;
              description = "Loki's IP address, the only one the shipper may reach.";
            };
            kinds = mkOption {
              type = types.listOf (types.strMatching "[a-z][a-z-]*");
              description = "The record kinds shipped, as the `kind` label; a line of any other kind is dropped.";
            };
            usage = mkOption {
              type = types.nullOr (types.strMatching "[1-9][0-9]*(s|min)");
              default = null;
              description = "How often dev-env-usage pushes each running instance's container cgroup counters and system, as host-made kind=usage records (nixos-config#494: per-task usage, joined to the coordinator's handoffs); null, never.";
            };
            fleet = mkOption {
              type = types.listOf (types.strMatching "[A-Za-z0-9][A-Za-z0-9-]*");
              description = "The fleet's hostnames: a guest line whose node= or owner= names one (or its flake attribute, the name before a dash) is dropped, so a guest cannot speak for a fleet host.";
            };
          };
        }
      );
      default = null;
      description = "Loki the host ships each guest's platform records to (the spool ~/.local/state/platform-records), every 5 minutes and before a home is trashed, labelled job=platform, kind and host=<prefix>-<name> by the host, never by the guest; null, not shipped.";
    };
    credentials = mkOption {
      type = types.attrsOf types.externalPath;
      default = { };
      example = {
        gh-hosts.yml = "/home/alice/.config/gh/hosts.yml";
      };
      description = "Host paths bound read-only at ${creds}/<name> in every guest.";
    };
    egress = mkOption {
      type = types.attrsOf (types.submodule egressModule);
      default = { };
      description = "Services the host's proxy signs for the instances.";
    };
    egressInaccessible = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Host paths the proxy may not read, besides stateDir.";
    };
    guestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      description = "NixOS modules of every guest; `devEnvironment` (name, hostName, address, credentials: the names bound) is their argument.";
    };
    sessionSurface = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            name = mkOption {
              type = types.strMatching "[a-z][a-z0-9-]*";
              description = "Its unit is <unitPrefix>-<name>-<instance>.";
            };
            script = mkOption {
              type = types.functionTo types.package;
              description = "Given an instance (with `ctl`, `agentDef`), a program run as the user: `start` once the container is up, `stop` when it goes.";
            };
          };
        }
      );
      default = null;
      description = "Where the agent's terminal lives (a multiplexer workspace); without one, `<unitPrefix>-<name> attach` opens it.";
    };
    prefix = mkOption {
      type = types.strMatching "[a-z][a-z0-9-]*";
      default = hostName;
      defaultText = "networking.hostName";
      description = "Instance x is hostname `<prefix>-x` inside and `x.<prefix>` on the host.";
    };
    unitPrefix = mkOption {
      type = types.strMatching "[a-z][a-z0-9-]*";
      default = "dev-env";
      description = "Units and the entry point are <unitPrefix>-<name>.";
    };
    stateDir = mkOption {
      type = types.strMatching "/var/lib/[a-z0-9-]+";
      default = "/var/lib/dev-environments";
      description = "Homes and the guests' host key.";
    };
    nameservers = mkOption {
      type = types.listOf (types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}");
      default = [ ];
      description = "IPv4 resolvers every guest uses instead of the stock copy of the host's resolv.conf, which can list only an IPv6 router-advertised server an IPv4-only guest cannot reach; empty keeps the copy.";
    };
    blockedNetworks = mkOption {
      type = types.listOf cidr;
      default = [ ];
      example = [ "192.168.10.0/24" ];
      description = "Networks the instances cannot reach through the host, and with any set not the host itself either, DNS (port 53) and the host's `http://<address>:<port>` substituters excepted; iptables firewall backend.";
    };
    jumpHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        work = "build-box";
      };
      description = "Client side: `ssh <name>.<prefix>` reaches instance <name> through the host this maps <prefix> to, a known host here.";
    };
    pool.memory = mkOption {
      type = size;
      description = "MemoryMax of the environments' slice, the only ceiling: every instance's reserve fits in it, swap is capped at a quarter of it. The host must have both free: the swap is zram, held in RAM.";
    };
  };

  config = lib.mkMerge [
    {
      services.devEnvironments = {
        uid = lib.mkIf ((hostUser.uid or null) != null) (lib.mkDefault hostUser.uid);
        agents = {
          claude = {
            command = lib.mkDefault [
              "claude"
              "--dangerously-skip-permissions"
            ];
            resumeArgs = lib.mkDefault [ "--continue" ];
            # Claude Code keeps a session's transcript under the project dir of the cwd it started in, the home here
            resumeWhen = lib.mkDefault ".claude/projects/${lib.replaceStrings [ "/" ] [ "-" ] home}/*.jsonl";
            readyText = lib.mkDefault "bypass permissions on";
          };
          codex.command = lib.mkDefault [
            "codex"
            "--dangerously-bypass-approvals-and-sandbox"
            "--dangerously-bypass-hook-trust"
          ];
        };
      };

      # Guest root writes as host root where nixpkgs' container module id-maps a writable bind (its per-container
      # profiles and roots): no setuid or device there, nor in the state dir. Not only while a rootInGuest instance
      # runs: what one planted would turn live once it is paused; retiring deletes its per-container dirs.
      fileSystems = lib.mkIf (cfg.instances != { } || cfg.retired != [ ]) (
        lib.genAttrs
          [ cfg.stateDir "/nix/var/nix/profiles/per-container" "/nix/var/nix/gcroots/per-container" ]
          (p: {
            device = p;
            fsType = "none";
            options = [
              "bind"
              "nosuid"
              "nodev"
              "x-mount.mkdir"
            ]
            ++ lib.optional (p != cfg.stateDir) "noexec";
          })
      );

      # Trashes only what `retired` names: a rollback or an older checkout that lacks an instance just stops it.
      system.activationScripts.devEnvironments = lib.mkIf (cfg.instances != { } || cfg.retired != [ ]) {
        deps = [ "users" ];
        text = ''
          d=${lib.escapeShellArg cfg.stateDir}
          [[ -d $d ]] && install -d -m 0700 "$d/.trash"
          for n in ${lib.escapeShellArgs cfg.retired}; do
            ${config.systemd.package}/bin/systemctl is-active --quiet "container@$n.service" && continue
            ${trashOne}
          done
          # a refusal fails dev-environments-trash, which alerts, not the activation
          ${lib.getExe trashSweep} "$d" || true
          ${prepareDirs}
        '';
      };

      # daily, not only at an activation: a reset trashes a home with no deploy
      systemd.services.dev-environments-trash = lib.mkIf (cfg.instances != { } || cfg.retired != [ ]) {
        description = "Delete the developer environments' homes trashed over a week ago";
        onFailure = lib.optional (cfg.instances != { } && cfg.alert != null) "dev-env-alert@%n.service";
        unitConfig.ConditionPathExists = "${cfg.stateDir}/.trash";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe trashSweep)
              cfg.stateDir
            ]
            ++ lib.optional (cfg.records != null) (
              lib.getExe (pkgs.callPackage ../../pkgs/platform-record/package.nix { })
            )
          );
          ProtectSystem = "strict";
          ReadWritePaths = [ cfg.stateDir ];
        }
        # with no records it records nothing, so it reaches nothing
        // (
          if cfg.records == null then
            { PrivateNetwork = true; }
          else
            {
              IPAddressDeny = "any";
              IPAddressAllow = cfg.records.address;
              # platform-record's spool and Loki-down marker: the only writable place under strict besides the state dir
              StateDirectory = "dev-environments-trash";
              StateDirectoryMode = "0700";
              Environment = [
                "PLATFORM_LOKI_URL=${cfg.records.url}"
                "PLATFORM_RECORD_SPOOL=/var/lib/dev-environments-trash/platform-records"
              ];
            }
        );
      };
      systemd.timers.dev-environments-trash = lib.mkIf (cfg.instances != { } || cfg.retired != [ ]) {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    }

    # the guest cannot reach Loki (blockedNetworks), and a push of its own could carry any labels
    (lib.mkIf ((cfg.instances != { } || cfg.retired != [ ]) && cfg.records != null) {
      systemd.services."dev-env-records@" = {
        description = "Ship developer environment %i's platform records to Loki";
        serviceConfig = recordsUnit [ "%i" ] "25s";
      };
      # a guest's stream is host=<prefix>-<name>, and `just deferred-checks` trusts a fleet host's stream as that host's
      assertions =
        let
          fleet = map lib.toLower cfg.records.fleet;
          clash = lib.filter (n: lib.elem (lib.toLower "${cfg.prefix}-${n}") fleet) (
            lib.attrNames cfg.instances ++ cfg.retired
          );
        in
        [
          {
            assertion = clash == [ ];
            message = "services.devEnvironments: the record stream of ${
              lib.concatMapStringsSep ", " (n: "${cfg.prefix}-${n}") clash
            } would equal a fleet host's name (sam.fleet.hosts), so its guest's records would read as that host's; rename the instance or the prefix.";
          }
        ];
    })
    (lib.mkIf (cfg.instances != { } && cfg.records != null) {
      systemd.services.dev-env-records = {
        description = "Ship the developer environments' platform records to Loki";
        serviceConfig =
          let
            u = recordsUnit (map (w: w.name) instances) "2min";
          in
          u
          // {
            ExecStart =
              u.ExecStart
              + " "
              + lib.escapeShellArgs [
                "--metrics"
                "${recordsMetrics}/guest-records.prom"
              ];
            SupplementaryGroups = [ "dev-env-records-metrics" ];
            ReadWritePaths = [ recordsMetrics ];
          };
      };
      users.groups.dev-env-records-metrics = { };
      services.prometheus.exporters.node.extraFlags = [
        "--collector.textfile.directory=${recordsMetrics}"
      ];
      # before the first run: node-exporter counts a missing directory as a textfile scrape error
      systemd.tmpfiles.rules = [ "d ${recordsMetrics} 0775 root dev-env-records-metrics -" ];
      systemd.timers.dev-env-records = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/5";
          Persistent = true;
        };
      };
    })
    (lib.mkIf (running != [ ] && cfg.records != null && cfg.records.usage != null) {
      systemd.services.dev-env-usage = {
        description = "Push the running developer environments' cgroup usage to Loki";
        serviceConfig = usageUnit (map (w: w.name) running);
      };
      systemd.timers.dev-env-usage = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = cfg.records.usage;
          AccuracySec = "1s";
        };
      };
    })

    # The host's daemon registers an environment's devenv roots under the guest's path, which dangles on the
    # host: without this the host's collection deletes every environment's built shells. The daemon also collects
    # on its own when min-free is set, so the timer refreshes the roots between the scheduled runs too.
    (lib.mkIf (cfg.instances != { }) {
      # `systemctl start dev-env-reset@<name>`: a fresh home for a declared instance without a deploy, refused while
      # its agent runs or a clone in it holds work that is not pushed (retire it to discard that on purpose).
      systemd.services."dev-env-reset@" = {
        description = "Reset developer environment %i to a fresh home";
        serviceConfig.Type = "oneshot";
        scriptArgs = "%i";
        path = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.util-linux
          config.systemd.package
        ];
        enableStrictShellChecks = true;
        script = ''
          n=$1
          names=${lib.escapeShellArg (lib.concatMapStringsSep " " (w: w.name) running)}
          [[ " $names " == *" $n "* ]] || { echo "$n: not a declared, unpaused instance" >&2; exit 1; }
          systemctl is-active --quiet "container@$n.service" || { echo "$n: container@$n is not running" >&2; exit 1; }
          # A real agent arrives over the guest's sshd, so it runs in the container unit's cgroup.
          cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value "container@$n.service")
          busy=$(find "$cg" -name cgroup.procs -exec cat {} + | while read -r pid; do
            mapfile -d ''' -t argv < "/proc/$pid/cmdline" 2>/dev/null || continue
            for a in "''${argv[@]:0:3}"; do
              case $a in claude | codex | */claude | */codex | */.claude-wrapped | */.codex-wrapped | *claude-code*/cli.js) echo "$pid"; break ;; esac
            done
          done) || true
          [[ -z $busy ]] || { echo "$n: an agent is running (pids ''${busy//$'\n'/ }); not reset" >&2; exit 1; }
          scratch=()
          case $n in
            ${lib.concatMapStrings (w: "${w.name}) scratch=(${lib.escapeShellArgs w.scratch}) ;;
") (
              lib.filter (w: w.scratch != [ ]) running
            )}
          esac
          # Run by the guest's own systemd as its user, inside the container's limits: git acts on the clones' config
          # (hooks, fsmonitor, filters), which must not run on the host.
          # shellcheck disable=SC2016 # the script expands inside the guest
          # --expand-environment=no: systemd would otherwise substitute each ''${...} in the script before bash sees it
          held=$(systemd-run -M "$n" --uid=${user} --expand-environment=no --wait --pipe --quiet -- ${pkgs.bash}/bin/bash -c '
            cd "$HOME" || { echo "the home cannot be entered"; exit 0; }
            skip=(); for s in "$@"; do skip+=(-path "./$s" -prune -o); done
            errs=$(${pkgs.findutils}/bin/find . -maxdepth 5 "''${skip[@]}" -name .git -prune -print 2>&1 >/dev/null)
            [[ -z $errs ]] || echo "paths under the home cannot be read"
            ${pkgs.findutils}/bin/find . -maxdepth 5 "''${skip[@]}" -name .git -prune -print 2>/dev/null | while read -r g; do
              r=''${g%/.git}
              st=$(${pkgs.git}/bin/git -C "$r" status --porcelain 2>&1) || st="unreadable: $st"
              [[ -z $st ]] || echo "$r: uncommitted changes or an unreadable repository"
              head=; ${pkgs.git}/bin/git -C "$r" rev-parse -q --verify HEAD >/dev/null && head=HEAD
              [[ -z $(${pkgs.git}/bin/git -C "$r" log --branches $head --not --remotes --oneline 2>&1) ]] || echo "$r: commits on no remote"
              [[ -z $(${pkgs.git}/bin/git -C "$r" stash list 2>&1) ]] || echo "$r: a stash"
            done
            exit 0
          ' bash "''${scratch[@]}") || { echo "$n: could not check the guest for unpushed work; not reset" >&2; exit 1; }
          [[ -z $held ]] || { printf '%s: not reset, the guest holds work that is not pushed:\n%s\n' "$n" "$held" >&2; exit 1; }
          systemctl stop "container@$n.service"
          install -d -m 0700 ${lib.escapeShellArg cfg.stateDir}/.trash
          if ! ${resetSteps} "$n"; then
            systemctl start "container@$n.service" || true
            echo "$n: the reset failed after the stop; the container was started again on what is left" >&2
            exit 1
          fi
          systemctl start "container@$n.service"
          echo "$n: reset; the old home is in ${cfg.stateDir}/.trash for a week"
        '';
      };

      systemd.timers.dev-environments-gcroots = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "15min";
        };
      };
      systemd.services.dev-environments-gcroots = {
        description = "Root the developer environments' devenv closures before garbage collection";
        requiredBy = lib.optionals config.nix.gc.automatic [ "nix-gc.service" ];
        before = lib.optionals config.nix.gc.automatic [ "nix-gc.service" ];
        serviceConfig.Type = "oneshot";
        enableStrictShellChecks = true;
        script = ''
          rc=0
          # refresh <tree> <roots>: a root in <roots> for each devenv link under <tree>
          refresh() {
            local home=$1 roots=$2 ok=1 found l t name r
            rm -f "$roots"/.home-*
            found=$(find "$home" -ignore_readdir_race \( -name node_modules -o -name target -o -name .git \) -prune \
              -o -path '*/.devenv/gc/*' -type l -print) || { ok=0; rc=1; }
            local -A keep=()
            while IFS= read -r l; do
              t=$(readlink "$l") || continue
              [[ $t == /nix/store/* && $t != *..* && -e $t ]] || continue
              name=home-$(echo -n "$l" | sha1sum | cut -c1-16)
              ln -sfn "$t" "$roots/.$name" && mv -T "$roots/.$name" "$roots/$name" || rc=1
              keep[$name]=1
            done <<< "$found"
            # only a complete scan may drop a root; a failed one keeps what it had and fails the unit, and with it nix-gc
            if (( ok )); then
              for r in "$roots"/home-*; do
                if [[ -L $r && -z ''${keep[''${r##*/}]-} ]]; then rm -f "$r"; fi
              done
            fi
          }
          for home in ${lib.escapeShellArg cfg.stateDir}/*/home; do
            n=''${home%/home}; n=''${n##*/}
            roots=/nix/var/nix/gcroots/per-container/$n
            [[ -d $roots ]] || continue
            refresh "$home" "$roots"
          done
          # A session's work tree, parked (.sessions/<id>/tree) or docked in a slot (.sessions/dock/<slot>/cur), each
          # under its own roots dir, parked/<id> or dock/<slot>. A dock or park moves the tree between two keys, possibly in the middle of this
          # run, so a key no longer found keeps its roots for an hour (each refresh rewrites a live key's dir).
          s=${lib.escapeShellArg cfg.stateDir}/.sessions
          if [[ -d $s ]]; then
            install -d -m 0755 ${sessionRoots}
            declare -A live=()
            for home in "$s"/*/tree/work "$s"/dock/*/cur/work; do
              [[ -d $home && ! -L $home ]] || continue
              case $home in
                "$s"/dock/*) k=''${home#"$s"/dock/} k=dock/''${k%/cur/work} ;;
                *) k=''${home#"$s"/} k=parked/''${k%/tree/work} ;;
              esac
              install -d -m 0755 "${sessionRoots}/''${k%/*}" "${sessionRoots}/$k"
              refresh "$home" "${sessionRoots}/$k"
              live[$k]=1
            done
            for r in ${sessionRoots}/{parked,dock}/*; do
              if [[ -d $r && ! -L $r && -z ''${live[''${r#${sessionRoots}/}]-} && -n $(find "$r" -maxdepth 0 -mmin +60) ]]; then rm -rf "$r"; fi
            done
          fi
          exit $rc
        '';
      };

      # Disk bytes and counts of the session trees, parked, docked and in the store (ExecPoolSessionsLarge), and of
      # .trash; no ids
      services.prometheus.exporters.node.extraFlags = [
        "--collector.textfile.directory=${sessionMetrics}"
      ];
      systemd.tmpfiles.rules = [ "d ${sessionMetrics} 0755 root root -" ];
      systemd.timers.dev-env-sessions-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "15min";
        };
      };
      systemd.services.dev-env-sessions-metrics = {
        description = "Size the developer environments' session trees and session store, for node-exporter";
        path = [ pkgs.coreutils ];
        enableStrictShellChecks = true;
        # root that only reads past the guests' modes and writes its own textfile
        serviceConfig = {
          Type = "oneshot";
          CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateNetwork = true;
          ReadWritePaths = [ sessionMetrics ];
          Nice = 19;
          IOSchedulingClass = "idle";
        };
        script = ''
          d=${lib.escapeShellArg cfg.stateDir}
          shopt -s nullglob
          # total <path>...: their disk bytes; a file a turn deletes mid-walk fails du, the total still counts the rest
          total() {
            local b=0
            (( $# == 0 )) || b=$({ du -scxB1 -- "$@" 2>/dev/null || true; } | tail -n 1 | cut -f1)
            [[ $b =~ ^[0-9]+$ ]] || { echo "du gave no total for $*" >&2; return 1; }
            echo "$b"
          }
          # emit <kind> <tree>...
          emit() {
            local kind=$1 b
            shift
            b=$(total "$@")
            printf 'homelab_dev_env_sessions_bytes{kind="%s"} %s\n' "$kind" "$b"
            printf 'homelab_dev_env_session_trees{kind="%s"} %s\n' "$kind" "$#"
          }
          trash=("$d"/.trash/*) parked=()
          for e in "$d"/.sessions/*/tree; do [[ $e == "$d"/.sessions/dock/tree ]] || parked+=("$e"); done
          tb=$(total "''${trash[@]}")
          fs=$(df -B1 --output=size "$d" | tail -n 1 | tr -d ' ')
          [[ $fs =~ ^[0-9]+$ ]] || { echo "df gave no size for $d" >&2; exit 1; }
          {
            # not .sessions/dock/tree, a slot named tree
            emit parked "''${parked[@]}"
            emit docked "$d"/.sessions/dock/*/cur
            emit store "$d"/.sessions-store/*
            # retired homes and removed sessions, freed a week after they were moved there
            printf 'homelab_dev_env_trash_bytes %s\n' "$tb"
            printf 'homelab_dev_env_trash_entries %s\n' "''${#trash[@]}"
            printf 'homelab_dev_env_sessions_filesystem_bytes %s\n' "$fs"
          } > ${sessionMetrics}/sessions.prom.tmp
          mv ${sessionMetrics}/sessions.prom.tmp ${sessionMetrics}/sessions.prom
        '';
      };
    })

    # A kernel kill or a full disk has no unit to fail: a timer reads the counter and df, so an alert is up to 2 minutes
    # late, a disk one at most hourly. State follows a sent alert, so a failed send is retried.
    (lib.mkIf (cfg.instances != { } && cfg.alert != null) (
      let
        sandboxed = {
          DynamicUser = true;
          ProtectSystem = "strict";
          PrivateTmp = true;
        };
      in
      {
        systemd.services."dev-env-alert@" = {
          serviceConfig = sandboxed // {
            Type = "oneshot";
          };
          scriptArgs = "%i";
          enableStrictShellChecks = true;
          script = ''${cfg.alert} "$1 failed on ${hostName}"'';
        };
        systemd.services.dev-env-watch = {
          serviceConfig = sandboxed // {
            Type = "oneshot";
            StateDirectory = "dev-env-watch";
          };
          path = [
            pkgs.coreutils
            pkgs.gawk
          ];
          enableStrictShellChecks = true;
          script = ''
            rc=0
            # no cgroup file (the slice has no unit yet) leaves now empty: skip the OOM check, still check the disks
            now=$(awk '$1 == "oom_kill" { print $2 }' /sys/fs/cgroup/${slice}.slice/memory.events 2>/dev/null) || now=
            if [[ -n $now ]]; then
              was=$(cat "$STATE_DIRECTORY/oom_kill" 2>/dev/null || echo "$now")
              (( now >= was )) || was=0
              if (( now == was )) || ${cfg.alert} "$((now - was)) process(es) in ${hostName}'s pool killed by the OOM killer"; then echo "$now" > "$STATE_DIRECTORY/oom_kill"; else rc=1; fi
            fi
            for dir in ${lib.escapeShellArg cfg.stateDir} /nix; do
              # a failed df leaves free empty: skip this directory, still check the next
              free=$(df --output=avail -BG "$dir" | tail -1 | tr -dc 0-9) || free=
              seen="$STATE_DIRECTORY/disk-$(echo "$dir" | tr / _)"
              if [[ -z $free ]] || ! (( free < 10 )); then continue; fi
              [[ -e $seen ]] && (( $(date +%s) - $(stat -c %Y "$seen") < 3600 )) && continue
              if ${cfg.alert} "${hostName}: $dir has ''${free}G free"; then touch "$seen"; else rc=1; fi
            done
            exit $rc
          '';
        };
        systemd.timers.dev-env-watch = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "2min";
          };
        };
      }
    ))

    (lib.mkIf (cfg.instances != { }) {
      assertions =
        let
          ours = map (w: w.address) instances;
          otherHosts = lib.concatLists (
            lib.attrValues (lib.filterAttrs (a: _: !lib.elem a ours) config.networking.hosts)
          );
          clashing = lib.filter (lib.hasPrefix "10.233.") (
            lib.concatMap (i: map (a: a.address) i.ipv4.addresses) (lib.attrValues config.networking.interfaces)
          );
          bothRetired = lib.intersectLists cfg.retired (lib.attrNames cfg.instances);
          p = "services.devEnvironments";
        in
        [
          {
            assertion = hostUser.isNormalUser or false;
            message = "${p}.user: ${user} is not a normal user of this host (users.users.${user}).";
          }
          {
            assertion = (hostUser.uid or null) == null || hostUser.uid == cfg.uid;
            message = "${p}.uid ${toString cfg.uid} is not users.users.${user}.uid.";
          }
          {
            assertion = cfg.sessionSurface == null || hostUser.linger or false == true;
            message = "${p}.sessionSurface runs as ${user} in their user manager, which needs users.users.${user}.linger = true.";
          }
          {
            assertion = bothRetired == [ ];
            message = "${p}.retired: ${lib.concatStringsSep ", " bothRetired} is also declared in instances.";
          }
          {
            assertion =
              cfg.blockedNetworks == [ ]
              || config.networking.firewall.enable && config.networking.firewall.backend == "iptables";
            message = "${p}.blockedNetworks needs the iptables firewall backend.";
          }
          {
            assertion = reservedMem <= cfg.pool.memory;
            message = "${p}.instances: their memory.reserved adds up to ${showSize reservedMem}, more than pool.memory ${showSize cfg.pool.memory}.";
          }
          {
            assertion = lib.allUnique (map (w: w.index) instances);
            message = "${p}.instances: two names hash to one address (10.233.<index>); rename one.";
          }
          {
            assertion = clashing == [ ];
            message = "${p}: the instances' 10.233.0.0/16 holds an address of this host (${lib.concatStringsSep ", " clashing}).";
          }
        ]
        ++ lib.mapAttrsToList (n: _: {
          assertion = builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" n != null && n != "ssh_host_ed25519_key";
          message = "${p}.credentials.${n}: a file name of [A-Za-z0-9_.-], and not the reserved ssh_host_ed25519_key.";
        }) cfg.credentials
        ++ lib.concatMap (
          w:
          let
            i = "${p}.instances.${w.name}";
          in
          [
            {
              assertion = w.agent != "none" || w.model == null;
              message = "${i}.model is set but agent is \"none\".";
            }
            {
              assertion = w.agent != "none" || w.prompt == null;
              message = "${i}.prompt is set but agent is \"none\".";
            }
            {
              assertion = w.prompt == null || cfg.sessionSurface != null;
              message = "${i}.prompt needs a sessionSurface to deliver it.";
            }
            {
              assertion = w.credentials == null || lib.all (n: cfg.credentials ? ${n}) w.credentials;
              message = "${i}.credentials names one that ${p}.credentials does not declare.";
            }
            {
              assertion = w.name != hostName;
              message = "${i}: the name is this host's own.";
            }
            {
              assertion = !lib.elem w.name otherHosts && !lib.elem "${w.name}.${cfg.prefix}" otherHosts;
              message = "${i}: networking.hosts already maps the name to another address.";
            }
            {
              assertion =
                lib.length (lib.filter (d: d ? ${w.name}) options.containers.definitions)
                == (if w.paused then 0 else 1);
              message = "${i}: containers.${w.name} is also declared elsewhere.";
            }
            {
              assertion = lib.stringLength w.hostName <= 63;
              message = "${i}: hostname ${w.hostName} is longer than 63.";
            }
            {
              assertion = !(w.sessionDock && w.rootInGuest);
              message = "${i}: sessionDock with rootInGuest: its writable binds are not id-mapped, so a session's tree could not move between slots.";
            }
            {
              assertion = !w.rootInGuest || gid != null;
              message = "${i}.rootInGuest maps ${user}'s group ${group}, which declares no gid.";
            }
            {
              assertion =
                !w.rootInGuest
                || lib.elem user config.nix.settings.allowed-users
                || lib.elem "*" config.nix.settings.allowed-users;
              message = "${i}.rootInGuest adds its guest user to nix.settings.allowed-users, which replaces the default \"*\": list every host user that runs nix there (${user} at least).";
            }
          ]
          ++ lib.optional (!w.paused) {
            assertion = config.containers.${w.name}.config.services.openssh.enable;
            message = "${i}: a guest module disabled sshd, the only way into it.";
          }
          ++ lib.optional (!w.paused) (
            let
              b = config.containers.${w.name}.bindMounts.${workLocks} or { };
              made = config.systemd.tmpfiles.settings.work-locks or { };
              dir = toString (b.hostPath or "");
            in
            {
              assertion =
                (b.isReadOnly or false)
                && lib.elem (b.mountPoint or null) [
                  workLocks
                  "${workLocks}:idmap"
                ]
                && (made.${dir} or { }) ? d
                && lib.all (lane: (made."${dir}/${lane}.lock" or { }) ? f) [
                  "heavy-work"
                  "light-work"
                ];
              message = "${i}: ${workLocks} must be bound read-only at ${workLocks} from the directory modules/core/work-locks.nix creates with its heavy-work and light-work lock files, or the guest's heavy jobs and the host's take different locks.";
            }
          )
        ) instances;

      # The daemon sees the guest user as the mapped uid, which machined names vu-<machine>-<uid>; neither guest root nor
      # a trusted user. Unresolved (machined gone) the daemon compares the bare uid, which matches nothing: it refuses.
      nix.settings.allowed-users = lib.mkIf (lib.any (w: w.rootInGuest) running) (
        map (w: "vu-${w.name}-${toString cfg.uid}") (lib.filter (w: w.rootInGuest) running)
      );

      containers = lib.listToAttrs (
        map (
          w:
          lib.nameValuePair w.name {
            ephemeral = true;
            autoStart = true;
            privateNetwork = true;
            inherit (w) hostAddress;
            localAddress = w.address;
            # above nspawn's `pick` range (0x80000 to 0x6fff0000), one 65536 block per index: fixed, so a host check can name it
            privateUsers = if w.rootInGuest then baseOf w else "no";
            # A numeric base implies --private-users-ownership=off (only `pick` implies auto): the ephemeral root stays the
            # host root's, nobody in the guest, and stage 2 can write neither /etc nor /bin. auto id-maps the root, which
            # needs idmapped-mount support from its filesystem (tmpfs, Linux 6.3 and later), and else chowns it.
            extraFlags = lib.optional w.rootInGuest "--private-users-ownership=auto";
            # Only read-only binds are id-mapped (identity: host 1000 is guest 1000); the host key is the guest root's own.
            bindMounts = lib.mapAttrs (
              n: b:
              b
              // lib.optionalAttrs (w.rootInGuest && b.isReadOnly && n != "${creds}/ssh_host_ed25519_key") {
                mountPoint = "${n}:idmap";
              }
            ) (binds w);
            config = guest w;
          }
        ) running
      );

      systemd.slices.${slice}.sliceConfig = {
        MemoryMax = cfg.pool.memory;
        MemoryLow = reservedMem;
        # The limit is the pool's, an instance has only its reserve: under an instance MemoryMax the kernel killed a
        # build at 6G in a 10G pool with one instance running. Past the pool and its swap it kills the largest process
        # in the slice. NOT MemoryHigh: a runaway then never reaches the limit and stalls the whole pool instead.
        # zram is charged to no cgroup and holds incompressible pages in RAM at full size: at half the pool a runaway
        # took msi (16G, 10G pool) into a host-wide OOM
        MemorySwapMax = cfg.pool.memory / 4;
      };

      systemd.services = lib.listToAttrs (
        lib.concatMap (
          w:
          [
            (lib.nameValuePair "container@${w.name}" {
              wants = lib.optional (
                cfg.sessionSurface != null
              ) "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}.service";
              # A changed guest (any guest module, nixpkgs) switches live through the stock ExecReload, which runs the new
              # system's switch-to-configuration inside: the agent's ssh session keeps running. Changed memory and CPU
              # properties take effect at the daemon-reload, also without a restart.
              reloadIfChanged = true;
              onFailure = lib.optional (cfg.alert != null) "dev-env-alert@%n.service";
              partOf = [ "${cfg.unitPrefix}-${w.name}.service" ];
              # Restart=on-failure and a guest that never gets ready cost a TimeoutStartSec per cycle, so the default limit (5 starts
              # in 10 s) never trips and the loop holds every job of the switch (the session, machines.target) open for good: 3 starts
              # in 10 minutes end it, and the unit stays failed until started by hand.
              startLimitIntervalSec = 600;
              startLimitBurst = 3;
              serviceConfig = {
                # mkForce: the stock unit puts every container in machine.slice
                Slice = lib.mkForce "${slice}.slice";
                MemoryLow = w.memory.reserved;
                # MemoryLow alone is given up once a neighbour has nothing left to reclaim: it took an idle instance to 59M
                MemoryMin = w.memory.reserved;
                CPUWeight = lib.min 10000 (100 * w.cpu.reserved);
                # Without nameservers the stock pre-start's copy of the host's resolv.conf is the guest's only DNS: at
                # boot or while a switch restarts NetworkManager it can have no nameserver yet.
                ExecStartPre = lib.mkBefore (
                  lib.optional (cfg.nameservers == [ ])
                    "-${pkgs.writeShellScript "worker-wait-resolv-conf" ''
                      for _ in {1..30}; do ${pkgs.gnugrep}/bin/grep -q ^nameserver /etc/resolv.conf && exit; ${pkgs.coreutils}/bin/sleep 1; done
                    ''}"
                  ++ [ "${idCheck} ${cfg.stateDir}/${w.name} ${toString (if w.rootInGuest then baseOf w else 0)}" ]
                );
              };
            })
            # A change of this unit file restarts it and so (PartOf) the container and its agent: it holds only what a
            # running container cannot take live, and no store path, which every nixpkgs bump would move (restartTriggers
            # is one too).
            (lib.nameValuePair "${cfg.unitPrefix}-${w.name}" {
              description = "Declaration of developer environment ${w.name}";
              wantedBy = [ "machines.target" ];
              wants = [ "container@${w.name}.service" ];
              path = lib.mkForce [ ];
              environment = lib.mapAttrs (_: _: null) config.systemd.globalEnvironment;
              unitConfig.X-Declaration = builtins.toJSON {
                inherit (w) agent model address;
                binds = binds w;
              };
              stopIfChanged = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "/bin/sh -c true";
              };
            })
          ]
          ++ lib.optional (cfg.sessionSurface != null) (
            lib.nameValuePair "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}" (
              let
                surface = cfg.sessionSurface.script (w // { ctl = lib.getExe (ctl w); });
              in
              {
                description = "Session surface of developer environment ${w.name}";
                bindsTo = [ "container@${w.name}.service" ];
                wants = [ "user@${toString cfg.uid}.service" ];
                # after user@: on shutdown it stops first, so the user's session server is still there to close it
                after = [
                  "container@${w.name}.service"
                  "user@${toString cfg.uid}.service"
                ];
                environment.XDG_RUNTIME_DIR = "/run/user/${toString cfg.uid}";
                # a restart would kill the running agent (its ssh): a deploy that only changes the surface leaves it be,
                # and a restart of the container brings it back
                restartIfChanged = false;
                onFailure = lib.optional (cfg.alert != null) "dev-env-alert@%n.service";
                serviceConfig = {
                  # simple, not oneshot: a deploy that adds an instance does not wait for its agent to come up
                  Type = "simple";
                  RemainAfterExit = true;
                  User = user;
                  # at a cold boot the user's session server can come up after the start gave up waiting for it
                  Restart = "on-failure";
                  RestartPreventExitStatus = 2; # the guest's home setup failed: a retry would start the agent on a first-run screen
                  RestartSec = 10;
                  ExecStart = "${lib.getExe surface} start";
                  ExecStop = "${lib.getExe surface} stop";
                };
              }
            )
          )
        ) running
      );

      environment.systemPackages = map ctl instances;
      system.build.devEnvironments = lib.listToAttrs (
        map (w: lib.nameValuePair w.name { start = agentScript w false; }) (
          lib.filter (w: w.agentDef != null) instances
        )
      );

      # egress for the instances' /16; an address with no running instance fails at once, not on a timeout
      networking.nat = {
        enable = true;
        internalIPs = [ "10.233.0.0/16" ];
      };
      networking.localCommands = "${pkgs.iproute2}/bin/ip route replace unreachable 10.233.0.0/16";
      networking.firewall = lib.mkIf (cfg.blockedNetworks != [ ]) {
        # INPUT too: a guest's connection to one of the host's own addresses (sshd, say) is never forwarded.
        # IPv6 is link-local only (no router advertises a prefix): the host's fe80 address answers ping and some ports
        # from the guest, so the same chain drops new connections there, with ICMPv6 left for neighbour discovery.
        extraCommands = ''
          iptables -w -D FORWARD -i ve-+ -j dev-env-forward 2>/dev/null || true
          iptables -w -D INPUT -i ve-+ -j dev-env-input 2>/dev/null || true
          iptables -w -F dev-env-forward 2>/dev/null || iptables -w -N dev-env-forward
          iptables -w -F dev-env-input 2>/dev/null || iptables -w -N dev-env-input
          for c in dev-env-forward dev-env-input; do
            iptables -w -A $c -p udp --dport 53 -j RETURN
            iptables -w -A $c -p tcp --dport 53 -j RETURN
            ${lib.concatMapStrings (
              m: "iptables -w -A $c -d ${lib.head m} -p tcp --dport ${lib.last m} -j RETURN\n            "
            ) lanCaches}
          done
          ${lib.concatMapStrings (c: "iptables -w -A dev-env-forward -d ${c} -j DROP
") cfg.blockedNetworks}
          iptables -w -A dev-env-input -m conntrack --ctstate NEW -j DROP
          iptables -w -I FORWARD -i ve-+ -j dev-env-forward
          iptables -w -I INPUT -i ve-+ -j dev-env-input
        ''
        + lib.optionalString config.networking.enableIPv6 ''
          ip6tables -w -D INPUT -i ve-+ -j dev-env-input 2>/dev/null || true
          ip6tables -w -D FORWARD -i ve-+ -j DROP 2>/dev/null || true
          ip6tables -w -F dev-env-input 2>/dev/null || ip6tables -w -N dev-env-input
          ip6tables -w -A dev-env-input -p ipv6-icmp -j RETURN
          ip6tables -w -A dev-env-input -m conntrack --ctstate NEW -j DROP
          ip6tables -w -I INPUT -i ve-+ -j dev-env-input
          ip6tables -w -I FORWARD -i ve-+ -j DROP
        '';
        extraStopCommands = ''
          iptables -w -D FORWARD -i ve-+ -j dev-env-forward 2>/dev/null || true
          iptables -w -D INPUT -i ve-+ -j dev-env-input 2>/dev/null || true
        ''
        + lib.optionalString config.networking.enableIPv6 ''
          ip6tables -w -D FORWARD -i ve-+ -j DROP 2>/dev/null || true
          ip6tables -w -D INPUT -i ve-+ -j dev-env-input 2>/dev/null || true
        '';
      };

      networking.hosts = lib.listToAttrs (
        map (
          w:
          lib.nameValuePair w.address [
            w.name
            "${w.name}.${cfg.prefix}"
          ]
        ) instances
      );
      programs.ssh.extraConfig = lib.concatMapStrings (
        w:
        ''
          Host ${w.name} ${w.name}.${cfg.prefix}
            User ${user}
        ''
        + lib.concatStrings (lib.mapAttrsToList (k: v: "  ${k} ${v}\n") (hostOptions w))
      ) instances;
    })

    {
      assertions =
        map (x: {
          assertion = x.path != null;
          message = x.missing;
        }) egressSecrets
        ++ [
          {
            message = "services.devEnvironments.egress: two services share a port or a secret name.";
            assertion =
              lib.allUnique (map (s: s.port) egressAll)
              && lib.allUnique (lib.concatMap (s: lib.attrNames s.secrets) egressAll);
          }
        ];
    }

    (lib.mkIf (egressed != [ ] && lib.all (x: x.path != null) egressSecrets) {
      systemd.services = {
        dev-env-egress = {
          description = "Signs the environments' calls to the services of services.devEnvironments.egress";
          wantedBy = [ "multi-user.target" ];
          onFailure = lib.optional (cfg.alert != null) "dev-env-alert@%n.service";
          environment.HOME = cfg.paths.egress.private;
          serviceConfig = {
            ExecStart = "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${caddyfile}";
            LoadCredential = map (x: "${x.n}:${x.path}") egressSecrets;
            ExecStartPre = lib.concatMap (s: s.prepare) egressUsed;
            User = user;
            RuntimeDirectory = [
              (baseNameOf egressDir)
            ]
            ++ map (w: "${baseNameOf egressDir}/${w.name}") egressed;
            # the guests bind this directory: removed at a restart, they would keep the old, empty one
            RuntimeDirectoryPreserve = true;
            # it parses the guests' requests as the host user: keep that user's other secrets and the guests' homes from it
            InaccessiblePaths = cfg.egressInaccessible ++ [ cfg.stateDir ];
            Restart = "on-failure";
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ProtectProc = "invisible";
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            SystemCallFilter = [ "@system-service" ];
          };
        };
      }
      // lib.genAttrs (map (w: "container@${w.name}") egressed) (_: {
        # the bind's source must exist when the container starts
        wants = [ "dev-env-egress.service" ];
        after = [ "dev-env-egress.service" ];
      });
    })

    (lib.mkIf (cfg.jumpHosts != { }) {
      assertions = lib.mapAttrsToList (prefix: host: {
        assertion =
          builtins.match "[a-z][a-z0-9-]*" prefix != null
          && lib.elem host (lib.concatMap (k: k.hostNames) (lib.attrValues config.programs.ssh.knownHosts));
        message = "services.devEnvironments.jumpHosts.${prefix}: the prefix is [a-z][a-z0-9-]*, and ${host} must be pinned in programs.ssh.knownHosts.";
      }) cfg.jumpHosts;
      # The environments' keys are generated on their host, so they cannot be pinned here: each name's is trusted on
      # first use, over a jump through the pinned host, kept apart from known_hosts. One entry per name, not one alias
      # per host: a rootInGuest instance has a key of its own, which this host cannot know of.
      programs.ssh.extraConfig = lib.concatStrings (
        lib.mapAttrsToList (prefix: host: ''
          Host *.${prefix}
            ProxyJump ${host}
            User ${user}
            UserKnownHostsFile ~/.ssh/known_hosts_environments
            StrictHostKeyChecking accept-new
            ConnectTimeout 10
            LogLevel ERROR
        '') cfg.jumpHosts
      );
    })
  ];
}
