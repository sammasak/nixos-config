# Declared developer environments, free of this fleet (modules/workers/default.nix is its adapter): each
# `services.devEnvironments.instances.<name>` is a stock `containers.<name>` with an ephemeral root, a persistent home
# and an agent reached over ssh; an instance moved to `retired` has its home deleted.
{ config, lib, pkgs, options, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.services.devEnvironments;
  user = cfg.user;
  hostUser = config.users.users.${user} or { };
  home = hostUser.home or "/home/${user}";
  group = hostUser.group or "users";
  hostName = config.networking.hostName;
  creds = "/var/lib/host-credentials";
  slice = "environments";

  multipliers = { "" = 1; K = 1024; M = 1048576; G = 1073741824; T = 1099511627776; };
  parseSize = s: let m = builtins.match "([0-9]+)([KMGT]?)" s; in lib.toInt (lib.head m) * multipliers.${lib.elemAt m 1};
  size = types.coercedTo (types.strMatching "[1-9][0-9]*[KMGT]?") parseSize types.ints.positive;
  showSize = b: "${toString (b / 1048576)}M";
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  cidr = types.strMatching "${octet}\\.${octet}\\.${octet}\\.${octet}/([0-9]|[12][0-9]|3[0-2])";
  nameType = types.strMatching "[a-z][a-z0-9-]{0,10}";
  keyAlias = "environments.${cfg.prefix}";
  # a fish single-quoted word reads \\ and \' as escapes, a POSIX one does not
  escape = if cfg.shell == "fish"
    then s: "'" + lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] s + "'"
    else lib.escapeShellArg;

  # From the name alone, so declaring or removing another instance never renumbers (and restarts) this one.
  indexOf = name: lib.mod (lib.fromHexString (lib.substring 0 4 (builtins.hashString "sha256" name))) 254 + 1;

  instances = lib.mapAttrsToList (_: i: i // rec {
    index = indexOf i.name;
    hostName = "${cfg.prefix}-${i.name}";
    hostAddress = "10.233.${toString index}.1";
    address = "10.233.${toString index}.2";
    agentDef = cfg.agents.${i.agent} or null;
  }) cfg.instances;

  argv = w: resume: w.agentDef.command ++ lib.optionals resume w.agentDef.resumeArgs
    ++ lib.optionals (w.model != null) (w.agentDef.modelArgs w.model);
  # The agent's command line as a file the guest's login shell sources: no user string is ever quoted for ssh.
  agentScript = w: resume: pkgs.writeText "${w.hostName}-${if resume then "continue" else "start"}.${cfg.shell}" ''
    ${lib.concatMapStringsSep " " escape (argv w resume)}
    exec ${cfg.shell} -il
  '';
  remote = w: resume: lib.escapeShellArg "${cfg.shell} -il -c ${lib.escapeShellArg "source ${agentScript w resume}"}";
  resumable = w: pkgs.writeShellApplication {
    name = "${w.hostName}-resumable";
    text = ''
      shopt -s nullglob
      found=("$HOME"/${w.agentDef.resumeWhen})
      (( ''${#found[@]} > 0 ))
    '';
  };

  knownHosts = "-o HostKeyAlias=${keyAlias} -o UserKnownHostsFile=${cfg.stateDir}/known_hosts -o StrictHostKeyChecking=yes";
  ssh = w: opts: "ssh ${opts} ${knownHosts} -o LogLevel=ERROR ${user}@${w.address}";
  # The instance's one entry point on the host: a session surface (or a person) runs `attach` in a terminal.
  ctl = w: pkgs.writeShellApplication {
    name = "${cfg.unitPrefix}-${w.name}";
    runtimeInputs = [ pkgs.coreutils pkgs.openssh ];
    text = ''
      case ''${1-} in
        wait)
          for _ in $(seq 120); do
            ${ssh w "-o BatchMode=yes -o ConnectTimeout=2"} true 2>/dev/null && exit 0
            sleep 1
          done
          exit 1 ;;
        resumable)
          ${if w.agentDef == null || w.agentDef.resumeWhen == null then "exit 1"
            else "${ssh w "-o BatchMode=yes"} ${lib.getExe (resumable w)} 2>/dev/null"} ;;
        attach)
          ${if w.agentDef == null then ''
            exec ${ssh w "-tt -o ConnectTimeout=10 -o ServerAliveInterval=30"}
          '' else ''
            cmd=${remote w false}
            if [[ ''${2-} == continue ]]; then cmd=${remote w true}; fi
            # Herdr detects the agent from the pane's foreground argv[0], so ssh is named after it
            exec -a ${w.agent} ${ssh w "-tt -o ConnectTimeout=10 -o ServerAliveInterval=30"} "$cmd"
          ''} ;;
        *) echo "usage: ${cfg.unitPrefix}-${w.name} wait|resumable|attach [fresh|continue]" >&2; exit 2 ;;
      esac
    '';
  };

  binds = w: {
    "${home}" = { hostPath = "${cfg.stateDir}/${w.name}/home"; isReadOnly = false; };
    "${creds}/ssh_host_ed25519_key" = { hostPath = "${cfg.stateDir}/ssh_host_ed25519_key"; isReadOnly = true; };
    "${creds}/${baseNameOf cfg.clientKey}.pub" = { hostPath = "${cfg.clientKey}.pub"; isReadOnly = true; };
  } // lib.mapAttrs' (n: src: lib.nameValuePair "${creds}/${n}" { hostPath = src; isReadOnly = true; }) cfg.credentials;

  guest = w: { ... }: {
    imports = cfg.guestModules;
    _module.args.devEnvironment = { inherit (w) name hostName address; };
    # the host user's uid: its credential files and nix daemon identity
    users.users.${user} = { isNormalUser = true; inherit (cfg) uid; };
    networking.hostName = w.hostName;
    programs.fish.enable = lib.mkIf (cfg.shell == "fish") true;

    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      # one key per host, generated at activation under stateDir and bound read-only: never the host's own sshd key
      hostKeys = [{ path = "${creds}/ssh_host_ed25519_key"; type = "ed25519"; }];
      authorizedKeysFiles = [ "${creds}/${baseNameOf cfg.clientKey}.pub" ];
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
    # an empty registry fetched the global one on every cold cache
    nix.settings.flake-registry = "";
    nix.registry.nixpkgs.to = { type = "path"; path = pkgs.path; };

    # lean: the boot is the start latency
    documentation.enable = false;
    services.udisks2.enable = false;
    xdg.sounds.enable = false;
  };

  agentModule = { name, ... }: {
    options = {
      name = mkOption { type = types.strMatching "[a-z][a-z0-9-]*"; default = name; readOnly = true; description = "The agent's name, also the argv[0] of its ssh."; };
      command = mkOption { type = types.nonEmptyListOf types.nonEmptyStr; description = "argv started in the guest's login shell; it ends in that shell."; };
      resumeArgs = mkOption { type = types.listOf types.nonEmptyStr; default = [ ]; description = "Appended when resumeWhen matches."; };
      resumeWhen = mkOption {
        type = types.nullOr (types.strMatching "[A-Za-z0-9._*-][A-Za-z0-9._/*-]*");
        default = null;
        description = "A glob under the guest home; a match at start means there is a session to resume.";
      };
      modelArgs = mkOption { type = types.functionTo (types.listOf types.nonEmptyStr); default = m: [ "--model" m ]; defaultText = "m: [ \"--model\" m ]"; description = "How the instance's model is passed."; };
      readyText = mkOption { type = types.nullOr types.nonEmptyStr; default = null; description = "Text the agent draws once it takes input, for a session surface to wait on."; };
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
      agent = mkOption { type = types.enum ([ "none" ] ++ lib.attrNames cfg.agents); default = "claude"; description = "One of `agents`, or `none` for a shell."; };
      model = mkOption { type = types.nullOr (types.strMatching "[][A-Za-z0-9._:-]+"); default = null; description = "The agent's model."; };
      prompt = mkOption { type = types.nullOr types.nonEmptyStr; default = null; description = "Sent by the session surface once the agent is ready, on a start with no session to resume."; };
      memory.reserved = mkOption { type = size; default = "2G"; description = "MemoryLow: kept from reclaim, and what the pool must fit."; };
      memory.max = mkOption { type = size; default = "6G"; description = "MemoryMax, the spike ceiling; MemoryHigh, where reclaim starts, is 90% of it and swap is capped at half of it."; };
      cpu.reserved = mkOption { type = types.ints.positive; default = 2; description = "Cores: CPUWeight 100 per core, a share under contention, all idle cores otherwise."; };
    };
  };
in
{
  options.services.devEnvironments = {
    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      example = { fix-ci = { model = "sonnet"; prompt = "Fix the failing test and push a branch."; }; };
      description = "Each runs, with a home that persists, while declared; once not, it is stopped and its home kept.";
    };
    retired = mkOption {
      type = types.listOf nameType;
      default = [ ];
      description = "Names whose home, profile and GC roots activation deletes, once their container is stopped.";
    };
    agents = mkOption { type = types.attrsOf (types.submodule agentModule); default = { }; description = "Agents an instance can run; claude and codex are predefined."; };
    user = mkOption { type = types.passwdEntry types.str; description = "The host user owning the environments; the guest gets the same user and uid."; };
    uid = mkOption { type = types.ints.positive; description = "That user's uid; defaults to the declared one."; };
    shell = mkOption { type = types.enum [ "bash" "fish" ]; default = "bash"; description = "The guest login shell the agent starts in."; };
    clientKey = mkOption {
      type = types.externalPath;
      default = "${home}/.ssh/id_ed25519";
      defaultText = "~user/.ssh/id_ed25519";
      description = "The host user's SSH key; its `.pub` is bound into the guest as the authorized key.";
    };
    credentials = mkOption {
      type = types.attrsOf types.externalPath;
      default = { };
      example = { gh-hosts.yml = "/home/alice/.config/gh/hosts.yml"; };
      description = "Host files bound read-only at ${creds}/<name> in every guest.";
    };
    guestModules = mkOption { type = types.listOf types.deferredModule; default = [ ]; description = "NixOS modules of every guest; `devEnvironment` (name, hostName, address) is their argument."; };
    sessionSurface = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          name = mkOption { type = types.strMatching "[a-z][a-z0-9-]*"; description = "Its unit is <unitPrefix>-<name>-<instance>."; };
          script = mkOption {
            type = types.functionTo types.package;
            description = "Given an instance (with `ctl`, `agentDef`), a program run as the user: `start` once the container is up, `stop` when it goes.";
          };
        };
      });
      default = null;
      description = "Where the agent's terminal lives (a multiplexer workspace); without one, `<unitPrefix>-<name> attach` opens it.";
    };
    prefix = mkOption { type = types.strMatching "[a-z][a-z0-9-]*"; default = hostName; defaultText = "networking.hostName"; description = "Instance x is hostname `<prefix>-x` inside and `x.<prefix>` on the host."; };
    unitPrefix = mkOption { type = types.strMatching "[a-z][a-z0-9-]*"; default = "dev-env"; description = "Units and the entry point are <unitPrefix>-<name>."; };
    stateDir = mkOption { type = types.strMatching "/var/lib/[a-z0-9-]+"; default = "/var/lib/dev-environments"; description = "Homes and the guests' host key."; };
    blockedNetworks = mkOption {
      type = types.listOf cidr;
      default = [ ];
      example = [ "192.168.10.0/24" ];
      description = "Networks the instances cannot reach through the host, DNS (port 53) excepted; iptables firewall backend.";
    };
    jumpHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { work = "build-box"; };
      description = "Client side: `ssh <name>.<prefix>` reaches instance <name> through the host this maps <prefix> to, a known host here.";
    };
    pool = {
      memory = mkOption { type = types.nullOr size; default = null; description = "MemoryMax of the environments' slice; every instance's reserve fits in it."; };
      cores = mkOption { type = types.nullOr types.ints.positive; default = null; description = "The host's cores, which the instances' reserved cores fit in."; };
    };
  };

  config = lib.mkMerge [
    {
      services.devEnvironments = {
        uid = lib.mkIf ((hostUser.uid or null) != null) (lib.mkDefault hostUser.uid);
        agents = {
          claude = {
            command = lib.mkDefault [ "claude" "--dangerously-skip-permissions" ];
            resumeArgs = lib.mkDefault [ "--continue" ];
            # Claude Code keeps a session's transcript under the project dir of the cwd it started in, the home here
            resumeWhen = lib.mkDefault ".claude/projects/${lib.replaceStrings [ "/" ] [ "-" ] home}/*.jsonl";
            readyText = lib.mkDefault "bypass permissions on";
          };
          codex.command = lib.mkDefault [ "codex" "--dangerously-bypass-approvals-and-sandbox" "--dangerously-bypass-hook-trust" ];
        };
      };

      # Deletes only what `retired` names: a rollback or an older checkout that lacks an instance just stops it.
      system.activationScripts.devEnvironments = lib.mkIf (cfg.instances != { } || cfg.retired != [ ]) {
        deps = [ "users" ];
        text = ''
          d=${lib.escapeShellArg cfg.stateDir}
          for n in ${lib.escapeShellArgs cfg.retired}; do
            ${config.systemd.package}/bin/systemctl is-active --quiet "container@$n.service" && continue
            rm -rf --one-file-system "$d/$n" "/nix/var/nix/profiles/per-container/$n" "/nix/var/nix/gcroots/per-container/$n"
          done
          install -d -m 0711 "$d"
          [[ -e $d/ssh_host_ed25519_key ]] || ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f "$d/ssh_host_ed25519_key"
          echo "${keyAlias} $(cut -d' ' -f1,2 "$d/ssh_host_ed25519_key.pub")" > "$d/known_hosts"
          chmod 0644 "$d/known_hosts"
          ${lib.concatMapStrings (w: ''
            install -d -m 0700 "$d/${w.name}"
            [[ -d $d/${w.name}/home ]] || install -d -m 0700 -o ${user} -g ${group} "$d/${w.name}/home"
          '') instances}
        '';
      };
    }

    # The host's daemon registers an environment's devenv roots under the guest's path, which dangles on the
    # host: without this the host's collection deletes every environment's built shells.
    (lib.mkIf (cfg.instances != { } && config.nix.gc.automatic) {
      systemd.services.dev-environments-gcroots = {
        description = "Root the developer environments' devenv closures before garbage collection";
        requiredBy = [ "nix-gc.service" ];
        before = [ "nix-gc.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          for home in ${lib.escapeShellArg cfg.stateDir}/*/home; do
            n=''${home%/home}; n=''${n##*/}
            roots=/nix/var/nix/gcroots/per-container/$n
            [[ -d $roots ]] || continue
            rm -f "$roots"/home-*
            ${pkgs.findutils}/bin/find "$home" \( -name node_modules -o -name target -o -name .git \) -prune \
              -o -path '*/.devenv/gc/*' -type l -print 2>/dev/null | while read -r l; do
              t=$(readlink "$l")
              [[ $t == /nix/store/* && -e $t ]] && ln -sfn "$t" "$roots/home-$(echo -n "$l" | sha1sum | cut -c1-16)"
            done
          done
        '';
      };
    })

    (lib.mkIf (cfg.instances != { }) {
      assertions =
        let
          reservedMem = lib.foldl' (s: w: s + w.memory.reserved) 0 instances;
          reservedCpu = lib.foldl' (s: w: s + w.cpu.reserved) 0 instances;
          ours = map (w: w.address) instances;
          otherHosts = lib.concatLists (lib.attrValues (lib.filterAttrs (a: _: !lib.elem a ours) config.networking.hosts));
          clashing = lib.filter (lib.hasPrefix "10.233.") (lib.concatMap (i: map (a: a.address) i.ipv4.addresses)
            (lib.attrValues config.networking.interfaces));
          bothRetired = lib.intersectLists cfg.retired (lib.attrNames cfg.instances);
          p = "services.devEnvironments";
        in
        [
          { assertion = hostUser.isNormalUser or false; message = "${p}.user: ${user} is not a normal user of this host (users.users.${user})."; }
          { assertion = (hostUser.uid or null) == null || hostUser.uid == cfg.uid; message = "${p}.uid ${toString cfg.uid} is not users.users.${user}.uid."; }
          {
            assertion = cfg.sessionSurface == null || hostUser.linger or false == true;
            message = "${p}.sessionSurface runs as ${user} in their user manager, which needs users.users.${user}.linger = true.";
          }
          { assertion = bothRetired == [ ]; message = "${p}.retired: ${lib.concatStringsSep ", " bothRetired} is also declared in instances."; }
          {
            assertion = cfg.blockedNetworks == [ ] || config.networking.firewall.enable && config.networking.firewall.backend == "iptables";
            message = "${p}.blockedNetworks needs the iptables firewall backend.";
          }
          { assertion = cfg.pool.memory != null; message = "${p}.pool.memory: a host that declares instances sets the memory pool they share."; }
          { assertion = cfg.pool.cores != null; message = "${p}.pool.cores: a host that declares instances sets its core count."; }
          {
            assertion = cfg.pool.memory == null || reservedMem <= cfg.pool.memory;
            message = "${p}.instances: their memory.reserved adds up to ${showSize reservedMem}, more than pool.memory ${showSize cfg.pool.memory}.";
          }
          {
            assertion = cfg.pool.cores == null || reservedCpu <= cfg.pool.cores;
            message = "${p}.instances: their cpu.reserved adds up to ${toString reservedCpu} cores, more than pool.cores ${toString cfg.pool.cores}.";
          }
          { assertion = lib.allUnique (map (w: w.index) instances); message = "${p}.instances: two names hash to one address (10.233.<index>); rename one."; }
          { assertion = clashing == [ ]; message = "${p}: the instances' 10.233.0.0/16 holds an address of this host (${lib.concatStringsSep ", " clashing})."; }
        ]
        ++ lib.mapAttrsToList (n: _: {
          assertion = builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" n != null && n != "ssh_host_ed25519_key";
          message = "${p}.credentials.${n}: a file name of [A-Za-z0-9_.-], and not the reserved ssh_host_ed25519_key.";
        }) cfg.credentials
        ++ lib.concatMap (w: let i = "${p}.instances.${w.name}"; in [
          { assertion = w.agent != "none" || w.model == null; message = "${i}.model is set but agent is \"none\"."; }
          { assertion = w.agent != "none" || w.prompt == null; message = "${i}.prompt is set but agent is \"none\"."; }
          { assertion = w.prompt == null || cfg.sessionSurface != null; message = "${i}.prompt needs a sessionSurface to deliver it."; }
          { assertion = w.memory.reserved <= w.memory.max; message = "${i}.memory: reserved ${showSize w.memory.reserved} is above max ${showSize w.memory.max}."; }
          {
            assertion = cfg.pool.memory == null || w.memory.max <= cfg.pool.memory;
            message = "${i}.memory.max ${showSize w.memory.max} is above pool.memory ${showSize cfg.pool.memory}.";
          }
          { assertion = w.name != hostName; message = "${i}: the name is this host's own."; }
          { assertion = !lib.elem w.name otherHosts && !lib.elem "${w.name}.${cfg.prefix}" otherHosts; message = "${i}: networking.hosts already maps the name to another address."; }
          { assertion = lib.length (lib.filter (d: d ? ${w.name}) options.containers.definitions) == 1; message = "${i}: containers.${w.name} is also declared elsewhere."; }
          { assertion = lib.stringLength w.hostName <= 63; message = "${i}: hostname ${w.hostName} is longer than 63."; }
          { assertion = config.containers.${w.name}.config.services.openssh.enable; message = "${i}: a guest module disabled sshd, the only way into it."; }
        ]) instances;

      containers = lib.listToAttrs (map (w: lib.nameValuePair w.name {
        ephemeral = true;
        autoStart = true;
        privateNetwork = true;
        inherit (w) hostAddress;
        localAddress = w.address;
        bindMounts = binds w;
        config = guest w;
      }) instances);

      systemd.slices.${slice}.sliceConfig = {
        MemoryMax = cfg.pool.memory;
        MemoryLow = lib.foldl' (s: w: s + w.memory.reserved) 0 instances;
      };

      systemd.services = lib.listToAttrs (lib.concatMap (w: [
        (lib.nameValuePair "container@${w.name}" {
          wants = lib.optional (cfg.sessionSurface != null) "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}.service";
          # A changed guest (any guest module, nixpkgs) switches live through the stock ExecReload, which runs the new
          # system's switch-to-configuration inside: the agent's ssh session keeps running. Changed memory and CPU
          # properties take effect at the daemon-reload, also without a restart.
          reloadIfChanged = true;
          partOf = [ "${cfg.unitPrefix}-${w.name}.service" ];
          serviceConfig = {
            # mkForce: the stock unit puts every container in machine.slice
            Slice = lib.mkForce "${slice}.slice";
            MemoryLow = w.memory.reserved;
            MemoryHigh = w.memory.max / 10 * 9;
            MemoryMax = w.memory.max;
            # Bounded so one runaway cannot fill the host's zram swap; past max + this the kernel kills the process, not the container.
            MemorySwapMax = w.memory.max / 2;
            CPUWeight = lib.min 10000 (100 * w.cpu.reserved);
            # The stock pre-start copies the host's resolv.conf, the guest's only DNS: at boot or while a switch
            # restarts NetworkManager it can have no nameserver yet, and the guest would boot without DNS.
            ExecStartPre = lib.mkBefore [
              "-${pkgs.writeShellScript "worker-wait-resolv-conf" ''
                for _ in {1..30}; do ${pkgs.gnugrep}/bin/grep -q ^nameserver /etc/resolv.conf && exit; ${pkgs.coreutils}/bin/sleep 1; done
              ''}"
            ];
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
          unitConfig.X-Declaration = builtins.toJSON { inherit (w) agent model address; binds = binds w; };
          stopIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "/bin/sh -c true";
          };
        })
      ] ++ lib.optional (cfg.sessionSurface != null) (lib.nameValuePair "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}" (
        let surface = cfg.sessionSurface.script (w // { ctl = lib.getExe (ctl w); }); in {
          description = "Session surface of developer environment ${w.name}";
          bindsTo = [ "container@${w.name}.service" ];
          wants = [ "user@${toString cfg.uid}.service" ];
          # after user@: on shutdown it stops first, so the user's session server is still there to close it
          after = [ "container@${w.name}.service" "user@${toString cfg.uid}.service" ];
          environment.XDG_RUNTIME_DIR = "/run/user/${toString cfg.uid}";
          # a restart would kill the running agent (its ssh): a deploy that only changes the surface leaves it be,
          # and a restart of the container brings it back
          restartIfChanged = false;
          serviceConfig = {
            # simple, not oneshot: a deploy that adds an instance does not wait for its agent to come up
            Type = "simple";
            RemainAfterExit = true;
            User = user;
            # at a cold boot the user's session server can come up after the start gave up waiting for it
            Restart = "on-failure";
            RestartSec = 10;
            ExecStart = "${lib.getExe surface} start";
            ExecStop = "${lib.getExe surface} stop";
          };
        }))) instances);

      environment.systemPackages = map ctl instances;
      system.build.devEnvironments = lib.listToAttrs (map (w: lib.nameValuePair w.name ({ ctl = ctl w; }
        // lib.optionalAttrs (w.agentDef != null) { start = agentScript w false; continue = agentScript w true; })) instances);

      # egress for the instances' /16; an address with no running instance fails at once, not on a timeout
      networking.nat = { enable = true; internalIPs = [ "10.233.0.0/16" ]; };
      networking.localCommands = "${pkgs.iproute2}/bin/ip route replace unreachable 10.233.0.0/16";
      networking.firewall = lib.mkIf (cfg.blockedNetworks != [ ]) {
        extraCommands = ''
          iptables -w -D FORWARD -i ve-+ -j dev-env-forward 2>/dev/null || true
          iptables -w -F dev-env-forward 2>/dev/null || iptables -w -N dev-env-forward
          iptables -w -A dev-env-forward -p udp --dport 53 -j RETURN
          iptables -w -A dev-env-forward -p tcp --dport 53 -j RETURN
          ${lib.concatMapStrings (c: "iptables -w -A dev-env-forward -d ${c} -j DROP
") cfg.blockedNetworks}
          iptables -w -I FORWARD -i ve-+ -j dev-env-forward
        '';
        extraStopCommands = "iptables -w -D FORWARD -i ve-+ -j dev-env-forward 2>/dev/null || true\n";
      };
      networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

      networking.hosts = lib.listToAttrs (map (w: lib.nameValuePair w.address [ w.name "${w.name}.${cfg.prefix}" ]) instances);
      programs.ssh.extraConfig = lib.concatMapStrings (w: ''
        Host ${w.name} ${w.name}.${cfg.prefix}
          User ${user}
          HostKeyAlias ${keyAlias}
          UserKnownHostsFile ${cfg.stateDir}/known_hosts
          StrictHostKeyChecking yes
          LogLevel ERROR
      '') instances;
    })

    (lib.mkIf (cfg.jumpHosts != { }) {
      assertions = lib.mapAttrsToList (prefix: host: {
        assertion = builtins.match "[a-z][a-z0-9-]*" prefix != null
          && lib.elem host (lib.concatMap (k: k.hostNames) (lib.attrValues config.programs.ssh.knownHosts));
        message = "services.devEnvironments.jumpHosts.${prefix}: the prefix is [a-z][a-z0-9-]*, and ${host} must be pinned in programs.ssh.knownHosts.";
      }) cfg.jumpHosts;
      # The environments' key is generated on their host, so it cannot be pinned here: it is trusted on first use,
      # over a jump through the pinned host, and kept apart from known_hosts.
      programs.ssh.extraConfig = lib.concatStrings (lib.mapAttrsToList (prefix: host: ''
        Host *.${prefix}
          ProxyJump ${host}
          User ${user}
          HostKeyAlias environments.${prefix}
          UserKnownHostsFile ~/.ssh/known_hosts_environments
          StrictHostKeyChecking accept-new
          ConnectTimeout 10
          LogLevel ERROR
      '') cfg.jumpHosts);
    })
  ];
}
