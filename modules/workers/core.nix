# Declared developer environments, free of this fleet (modules/workers/default.nix is its adapter): each
# `services.devEnvironments.instances.<name>` is a stock `containers.<name>` with an ephemeral root, a persistent home
# and an agent reached over ssh; a deploy that no longer declares one deletes its home.
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
  # a fish single-quoted word reads \\ and \' as escapes, a POSIX one does not
  escape = if cfg.shell == "fish"
    then s: "'" + lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] s + "'"
    else lib.escapeShellArg;

  # From the name alone, so declaring or removing another instance never renumbers (and restarts) this one.
  indexOf = name: lib.mod (lib.fromHexString (lib.substring 0 4 (builtins.hashString "sha256" name))) 254 + 1;
  subnetBits = lib.foldl' (a: o: a * 256 + lib.toInt o) 0 (lib.splitString "." cfg.subnet);
  # true when the CIDR shares an address with <subnet>.0.0/16
  overlaps = c:
    let
      p = lib.splitString "/" c;
      o = map lib.toInt (lib.splitString "." (lib.head p));
      len = lib.min 16 (lib.toInt (lib.elemAt p 1));
      div = lib.foldl' (a: _: a * 2) 1 (lib.range 1 (16 - len));
    in (lib.elemAt o 0 * 256 + lib.elemAt o 1) / div == subnetBits / div;

  instances = lib.mapAttrsToList (_: i: i // rec {
    index = indexOf i.name;
    hostName = "${cfg.prefix}-${i.name}";
    hostAddress = "${cfg.subnet}.${toString index}.1";
    address = "${cfg.subnet}.${toString index}.2";
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

  ssh = w: opts: "ssh ${opts} -o HostKeyAlias=${hostName} -o LogLevel=ERROR ${user}@${w.address}";
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
      # the host's own key, bound read-only: stable across boots and already pinned where the host is
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
        type = types.strMatching "[a-z][a-z0-9-]{0,10}";
        default = name;
        readOnly = true;
        description = "At most 11 of [a-z0-9-], starting with a letter: the veth is ve-<name>.";
      };
      agent = mkOption { type = types.enum ([ "none" ] ++ lib.attrNames cfg.agents); default = "claude"; description = "One of `agents`, or `none` for a shell."; };
      model = mkOption { type = types.nullOr (types.strMatching "[][A-Za-z0-9._:-]+"); default = null; description = "The agent's model."; };
      prompt = mkOption { type = types.nullOr types.nonEmptyStr; default = null; description = "Sent by the session surface once the agent is ready, on a start with no session to resume."; };
      memory.reserved = mkOption { type = size; default = "2G"; description = "MemoryLow: kept from reclaim, and what the pool must fit."; };
      memory.max = mkOption { type = size; default = "6G"; description = "MemoryMax, the spike ceiling; MemoryHigh, where reclaim starts, is 90% of it."; };
      cpu.reserved = mkOption { type = types.ints.positive; default = 2; description = "Cores: CPUWeight 100 per core, a share under contention, all idle cores otherwise."; };
      cpu.max = mkOption { type = types.nullOr types.ints.positive; default = null; description = "A hard CPUQuota in cores; null spikes to every core."; };
    };
  };
in
{
  options.services.devEnvironments = {
    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      example = { fix-ci = { model = "sonnet"; prompt = "Fix the failing test and push a branch."; }; };
      description = "Each runs, with a home that persists, while declared, and is deleted once not.";
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
    hostKey = mkOption { type = types.externalPath; description = "The host's ed25519 key the guest presents; defaults to the host sshd's."; };
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
    stateDir = mkOption { type = types.externalPath; default = "/var/lib/dev-environments"; description = "Homes; a name under it no longer declared is deleted at activation."; };
    subnet = mkOption { type = types.strMatching "${octet}\\.${octet}"; default = "10.233"; description = "The /16 the instances' veth pairs take addresses from."; };
    hostSubnets = mkOption { type = types.listOf cidr; default = [ ]; description = "Networks of the host that `subnet` must not overlap, beside its interfaces' addresses."; };
    jumpHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { work = "build-box"; };
      description = "Client side: `ssh <name>.<prefix>` reaches instance <name> through the host this maps <prefix> to, a known host here.";
    };
    pool = {
      memory = mkOption { type = types.nullOr size; default = null; description = "MemoryMax of the environments' slice; every instance's reserve fits in it."; };
      cores = mkOption { type = types.nullOr types.ints.positive; default = null; description = "The host's cores, which the instances' reserved cores fit in."; };
      cpuWeight = mkOption { type = types.ints.between 1 10000; default = 100; description = "CPUWeight of the slice against the host's other slices."; };
    };
  };

  config = lib.mkMerge [
    {
      services.devEnvironments = {
        uid = lib.mkIf ((hostUser.uid or null) != null) (lib.mkDefault hostUser.uid);
        hostKey = let k = lib.findFirst (k: k.type == "ed25519") null config.services.openssh.hostKeys;
          in lib.mkIf (k != null) (lib.mkDefault k.path);
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

      # After the switch stopped a removed instance: its home and the stock module's per-container dirs go; a
      # still-running container (a failed stop) is left alone.
      system.activationScripts.devEnvironments = {
        deps = [ "users" ];
        text = ''
          for d in ${cfg.stateDir}/*; do
            [[ -d $d ]] || continue
            n=''${d##*/}
            case " ${lib.concatMapStringsSep " " (w: w.name) instances} " in *" $n "*) continue ;; esac
            ${config.systemd.package}/bin/systemctl is-active --quiet "container@$n.service" && continue
            rm -rf --one-file-system "$d" "/nix/var/nix/profiles/per-container/$n" "/nix/var/nix/gcroots/per-container/$n"
          done
          ${if instances == [ ] then "rmdir ${cfg.stateDir} 2>/dev/null || true" else "install -d -m 0700 ${cfg.stateDir}"}
          ${lib.concatMapStrings (w: ''
            install -d -m 0700 ${cfg.stateDir}/${w.name}
            [[ -d ${cfg.stateDir}/${w.name}/home ]] || install -d -m 0700 -o ${user} -g ${group} ${cfg.stateDir}/${w.name}/home
          '') instances}
        '';
      };
    }

    (lib.mkIf (cfg.instances != { }) {
      assertions =
        let
          known = lib.concatMap (k: k.hostNames) (lib.attrValues config.programs.ssh.knownHosts);
          reservedMem = lib.foldl' (s: w: s + w.memory.reserved) 0 instances;
          reservedCpu = lib.foldl' (s: w: s + w.cpu.reserved) 0 instances;
          ours = map (w: w.address) instances;
          otherHosts = lib.concatLists (lib.attrValues (lib.filterAttrs (a: _: !lib.elem a ours) config.networking.hosts));
          hostCidrs = cfg.hostSubnets ++ lib.concatMap (i: map (a: "${a.address}/${toString a.prefixLength}") i.ipv4.addresses)
            (lib.attrValues config.networking.interfaces);
          referenced = lib.concatMap (s: s.wants ++ s.after ++ s.bindsTo ++ s.partOf ++ s.wantedBy)
            (lib.attrValues (lib.filterAttrs (n: _: lib.hasPrefix "${cfg.unitPrefix}-" n) config.systemd.services));
          missingUnits = lib.filter (u: lib.hasSuffix ".service" u && !(config.systemd.units ? ${u})
            && builtins.match "user@[0-9]+\\.service" u == null) referenced;
          p = "services.devEnvironments";
        in
        [
          { assertion = hostUser.isNormalUser or false; message = "${p}.user: ${user} is not a normal user of this host (users.users.${user})."; }
          { assertion = (hostUser.uid or null) == null || hostUser.uid == cfg.uid; message = "${p}.uid ${toString cfg.uid} is not users.users.${user}.uid."; }
          {
            assertion = cfg.sessionSurface == null || hostUser.linger or false == true;
            message = "${p}.sessionSurface runs as ${user} in their user manager, which needs users.users.${user}.linger = true.";
          }
          { assertion = config.services.openssh.enable; message = "${p}: the guests present the host's sshd key (hostKey), so services.openssh must be enabled here."; }
          {
            assertion = lib.elem hostName known;
            message = "${p}: the host's own ssh checks a guest's key under ${hostName} (HostKeyAlias), which programs.ssh.knownHosts does not pin.";
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
          { assertion = lib.allUnique (map (w: w.index) instances); message = "${p}.instances: two names hash to one address (${cfg.subnet}.<index>); rename one."; }
          { assertion = !lib.any overlaps hostCidrs; message = "${p}.subnet ${cfg.subnet}.0.0/16 overlaps a network of this host (${lib.concatStringsSep ", " (lib.filter overlaps hostCidrs)})."; }
          { assertion = missingUnits == [ ]; message = "${p}: units reference undeclared units: ${lib.concatStringsSep ", " missingUnits}."; }
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
          {
            assertion = w.cpu.max == null || (w.cpu.max >= w.cpu.reserved && (cfg.pool.cores == null || w.cpu.max <= cfg.pool.cores));
            message = "${i}.cpu.max must be at least cpu.reserved and at most pool.cores.";
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
        bindMounts = {
          "${home}" = { hostPath = "${cfg.stateDir}/${w.name}/home"; isReadOnly = false; };
          "${creds}/ssh_host_ed25519_key" = { hostPath = cfg.hostKey; isReadOnly = true; };
          "${creds}/${baseNameOf cfg.clientKey}.pub" = { hostPath = "${cfg.clientKey}.pub"; isReadOnly = true; };
        } // lib.mapAttrs' (n: src: lib.nameValuePair "${creds}/${n}" { hostPath = src; isReadOnly = true; }) cfg.credentials;
        config = guest w;
      }) instances);

      systemd.slices.${slice}.sliceConfig = {
        MemoryMax = cfg.pool.memory;
        MemoryLow = lib.foldl' (s: w: s + w.memory.reserved) 0 instances;
        CPUWeight = cfg.pool.cpuWeight;
      };

      systemd.services = lib.listToAttrs (lib.concatMap (w: [
        (lib.nameValuePair "container@${w.name}" {
          wants = lib.optional (cfg.sessionSurface != null) "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}.service";
          # A changed guest (any guest module, nixpkgs) switches live through the stock ExecReload, which runs the new
          # system's switch-to-configuration inside: the agent's ssh session keeps running.
          reloadIfChanged = true;
          partOf = [ "${cfg.unitPrefix}-${w.name}.service" ];
          serviceConfig = {
            # mkForce: the stock unit puts every container in machine.slice
            Slice = lib.mkForce "${slice}.slice";
            MemoryLow = w.memory.reserved;
            MemoryHigh = w.memory.max / 10 * 9;
            MemoryMax = w.memory.max;
            CPUWeight = lib.min 10000 (100 * w.cpu.reserved);
          } // lib.optionalAttrs (w.cpu.max != null) { CPUQuota = "${toString (100 * w.cpu.max)}%"; } // {
            # The stock pre-start copies the host's resolv.conf, the guest's only DNS: at boot or while a switch
            # restarts NetworkManager it can have no nameserver yet, and the guest would boot without DNS.
            ExecStartPre = lib.mkBefore [
              "-${pkgs.writeShellScript "worker-wait-resolv-conf" ''
                for _ in {1..30}; do ${pkgs.gnugrep}/bin/grep -q ^nameserver /etc/resolv.conf && exit; ${pkgs.coreutils}/bin/sleep 1; done
              ''}"
            ];
          };
        })
        # The instance's own declaration: a change restarts this unit, and so (PartOf) the container and its agent.
        (lib.nameValuePair "${cfg.unitPrefix}-${w.name}" {
          description = "Declaration of developer environment ${w.name}";
          wantedBy = [ "machines.target" ];
          wants = [ "container@${w.name}.service" ];
          restartTriggers = [ (builtins.toJSON { inherit (w) agent model prompt memory cpu; }) ];
          stopIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        })
      ] ++ lib.optional (cfg.sessionSurface != null) (lib.nameValuePair "${cfg.unitPrefix}-${cfg.sessionSurface.name}-${w.name}" (
        let surface = cfg.sessionSurface.script (w // { ctl = lib.getExe (ctl w); }); in {
          description = "Session surface of developer environment ${w.name}";
          bindsTo = [ "container@${w.name}.service" ];
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
            ExecStart = "${lib.getExe surface} start";
            ExecStop = "${lib.getExe surface} stop";
          };
        }))) instances);

      environment.systemPackages = map ctl instances;
      system.build.devEnvironments = lib.listToAttrs (map (w: lib.nameValuePair w.name ({ ctl = ctl w; }
        // lib.optionalAttrs (w.agentDef != null) { start = agentScript w false; continue = agentScript w true; })) instances);

      # egress for the instances' /16; an address with no running instance fails at once, not on a timeout
      networking.nat = { enable = true; internalIPs = [ "${cfg.subnet}.0.0/16" ]; };
      networking.localCommands = "${pkgs.iproute2}/bin/ip route replace unreachable ${cfg.subnet}.0.0/16";
      networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

      networking.hosts = lib.listToAttrs (map (w: lib.nameValuePair w.address [ w.name "${w.name}.${cfg.prefix}" ]) instances);
      # the guest presents its host's key (bound read-only), pinned under the host's name
      programs.ssh.extraConfig = lib.concatMapStrings (w: ''
        Host ${w.name} ${w.name}.${cfg.prefix}
          User ${user}
          HostKeyAlias ${hostName}
          LogLevel ERROR
      '') instances;
    })

    (lib.mkIf (cfg.jumpHosts != { }) {
      assertions = lib.mapAttrsToList (prefix: host: {
        assertion = builtins.match "[a-z][a-z0-9-]*" prefix != null
          && lib.elem host (lib.concatMap (k: k.hostNames) (lib.attrValues config.programs.ssh.knownHosts));
        message = "services.devEnvironments.jumpHosts.${prefix}: the prefix is [a-z][a-z0-9-]*, and ${host} must be pinned in programs.ssh.knownHosts (HostKeyAlias).";
      }) cfg.jumpHosts;
      programs.ssh.extraConfig = lib.concatStrings (lib.mapAttrsToList (prefix: host: ''
        Host *.${prefix}
          ProxyJump ${host}
          User ${user}
          HostKeyAlias ${host}
          ConnectTimeout 10
          LogLevel ERROR
      '') cfg.jumpHosts);
    })
  ];
}
