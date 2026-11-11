# Declared developer environments (docs/nspawn-workers.md): each `sam.workers.instances.<name>` is a stock
# `containers.<name>` with an ephemeral root and a persistent home, running claude or codex from the host's
# /nix/store and nix daemon as a workspace in the host's own Herdr; a deploy without it deletes its home.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers;
  profile = config.sam.profile;
  user = profile.username;
  home = "/home/${user}";
  creds = "/var/lib/host-credentials";
  # Only this module writes here; a name under it that is no longer declared is deleted at activation.
  stateDir = "/var/lib/workers";
  uid = if config.users.users.${user}.uid != null then config.users.users.${user}.uid else 1000;

  memSize = types.strMatching "[1-9][0-9]*[MG]";
  toMiB = s: lib.toInt (lib.substring 0 (lib.stringLength s - 1) s) * (if lib.hasSuffix "G" s then 1024 else 1);

  # From the name alone, so declaring or removing another instance never renumbers (and restarts) this one.
  indexOf = name: lib.mod (lib.fromHexString (lib.substring 0 4 (builtins.hashString "sha256" name))) 254 + 1;

  instances = lib.mapAttrsToList (name: i: i // rec {
    inherit name;
    index = indexOf name;
    label = "${cfg.labelPrefix}-${name}";
    hostAddress = "10.233.${toString index}.1";
    address = "10.233.${toString index}.2";
  }) cfg.instances;

  remoteCommand = w: resume: {
    claude = "fish -il -c 'claude --dangerously-skip-permissions${lib.optionalString resume " --continue"}${lib.optionalString (w.model != null) " --model ${w.model}"}; exec fish -il'";
    codex = "fish -il -c 'codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust${lib.optionalString (w.model != null) " --model ${w.model}"}; exec fish -il'";
  }.${w.agent};

  # Claude Code keeps a session's transcript under the project dir of the cwd it started in, the home here.
  transcripts = ".claude/projects/${lib.replaceStrings [ "/" ] [ "-" ] home}";

  # Herdr detects the agent from the pane's foreground argv[0]: the ssh process is named after it, and the
  # agent's status then comes from the screen and terminal title, which ssh passes through.
  session = w: pkgs.writeShellScript "worker-${w.name}-session" ''
    cmd=${lib.optionalString (w.agent != "none") (lib.escapeShellArg (remoteCommand w false))}
    if [[ ''${1-} == continue ]]; then cmd=${lib.optionalString (w.agent != "none") (lib.escapeShellArg (remoteCommand w true))}; fi
    exec ${lib.optionalString (w.agent != "none") "-a ${w.agent}"} ${pkgs.openssh}/bin/ssh -tt \
      -o HostKeyAlias=${config.networking.hostName} -o ConnectTimeout=10 -o ServerAliveInterval=30 -o LogLevel=ERROR \
      ${user}@${w.address} ''${cmd:+"$cmd"}
  '';

  hook = w: pkgs.writeShellApplication {
    name = "worker-herdr-${w.name}";
    runtimeInputs = [ pkgs.coreutils pkgs.herdr pkgs.jq pkgs.openssh ];
    text = ''
      label=${w.name}
      close() {
        herdr workspace list 2>/dev/null | jq -r --arg l "$label" '.result.workspaces[]? | select(.label == $l) | .workspace_id' \
          | while read -r id; do herdr workspace close "$id" >/dev/null || true; done
      }
      if [[ $1 == stop ]]; then close; exit 0; fi

      for _ in $(seq 60); do herdr status --json 2>/dev/null | jq -e '.server.running' >/dev/null && break; sleep 1; done
      for _ in $(seq 120); do
        ssh -o BatchMode=yes -o HostKeyAlias=${config.networking.hostName} -o ConnectTimeout=2 -o LogLevel=ERROR \
          ${user}@${w.address} true 2>/dev/null && break
        sleep 1
      done
      mode="fresh"
      ${lib.optionalString (w.agent == "claude") ''
        if [[ -n $(ssh -o BatchMode=yes -o HostKeyAlias=${config.networking.hostName} -o LogLevel=ERROR ${user}@${w.address} \
          find ${transcripts} -maxdepth 1 -name "'*.jsonl'" -print -quit 2>/dev/null) ]]; then
          mode="continue"
        fi
      ''}
      close
      pane=$(herdr workspace create --label "$label" --no-focus | jq -er '.result.root_pane.pane_id')
      herdr pane run "$pane" "${session w} $mode" >/dev/null
      ${lib.optionalString (w.agent != "none") ''
        # past this point a failure must not fail the unit, or its stop (closing the workspace) never runs
        for _ in $(seq 180); do
          herdr agent list 2>/dev/null | jq -e --arg p "$pane" '.result.agents[]? | select(.pane_id == $p)' >/dev/null && break
          sleep 1
        done
        herdr agent rename "$pane" "$label" >/dev/null || echo "Herdr detected no ${w.agent} in $label" >&2
        # Herdr calls the pane idle on the host's fish prompt already; claude takes input once its footer is drawn
        if ${lib.optionalString (w.agent == "claude") ''herdr pane wait-output "$pane" --match "bypass permissions on" --source visible --timeout 180000 >/dev/null &&''} \
          herdr agent wait "$pane" --until idle --timeout 30000 >/dev/null; then
          :
          ${lib.optionalString (w.prompt != null) ''
            # an agent that only just drew its prompt box can drop the submitting Enter, leaving the text typed
            if [[ $mode == continue ]]; then
              :
            elif ! herdr agent prompt "$pane" ${lib.escapeShellArg w.prompt} --wait --until working --until "done" \
              --timeout 15000 >/dev/null 2>&1; then
              herdr agent send-keys "$pane" Enter >/dev/null || true
            fi
          ''}
        else
          echo "${w.agent} in $label did not reach idle; see the workspace" >&2
        fi
      ''}
    '';
  };

  guest = w: { ... }: {
    imports = [
      ../core/system.nix
      ../core/users.nix
      ../core/packages.nix
      ../core/ssh-known-hosts.nix
    ] ++ cfg.guestModules;

    # not nixpkgs.pkgs = pkgs: core/system.nix sets nixpkgs.config, which an external instance refuses
    nixpkgs.overlays = config.nixpkgs.overlays;
    sam.profile = profile // { hostname = w.label; roles = [ "base" ]; pi = false; };
    sam.userConfig = config.sam.userConfig;
    # the host's lukas is uid 1000 (mutable allocation): its credential files and nix daemon identity
    users.users.${user}.uid = uid;
    networking.hostName = w.label;
    programs.fish.enable = true;

    sam.herdr.worker.enable = true;
    sam.herdr.trustedDirs = map (d: "${home}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      # the host's own key, bound read-only: stable across boots and already pinned on every fleet host
      hostKeys = [{ path = "${creds}/ssh_host_ed25519_key"; type = "ed25519"; }];
      # the host user's own key, so the host's Herdr pane can open the worker's agent
      authorizedKeysFiles = lib.optional (cfg.sshKey != null) "${creds}/id_ed25519.pub";
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ user ];
      };
    };

    # The host's credentials, bound read-only under ${creds}, where the host's own tools look for them.
    systemd.tmpfiles.rules = [
      "d ${home}/.ssh 0700 ${user} users -"
      "d ${home}/.config 0700 ${user} users -"
    ]
    ++ lib.optional (cfg.sshKey != null) "L+ ${home}/.ssh/id_ed25519 - - - - ${creds}/id_ed25519"
    ++ lib.optionals (cfg.ghHostsFile != null) [
      "d ${home}/.config/gh 0700 ${user} users -"
      "L+ ${home}/.config/gh/hosts.yml - - - - ${creds}/gh-hosts.yml"
    ]
    ++ lib.optional config.sam.hostSecrets.enable "L+ /run/secrets/claude_oauth_token - - - - ${creds}/claude_oauth_token";

    # lean: the boot is the start latency
    documentation.enable = false;
    services.udisks2.enable = false;
    xdg.sounds.enable = false;
  };

  instanceModule = { ... }: {
    options = {
      agent = mkOption {
        type = types.enum [ "claude" "codex" "none" ];
        default = "claude";
        description = "Agent the Herdr pane runs in the environment, without approval prompts; `none` is a shell.";
      };
      model = mkOption { type = types.nullOr (types.strMatching "[][A-Za-z0-9._:-]+"); default = null; description = "The agent's `--model`."; };
      prompt = mkOption { type = types.nullOr types.str; default = null; description = "Sent to the agent once idle, on a start with no earlier Claude session to continue."; };
      memoryMax = mkOption { type = memSize; default = cfg.memoryMax; description = "MemoryMax (its nix builds run in the host daemon, outside it)."; };
      cpuQuota = mkOption { type = types.str; default = cfg.cpuQuota; description = "CPUQuota."; };
    };
  };
in
{
  options.sam.workers = {
    instances = mkOption {
      type = types.attrsOf (types.submodule instanceModule);
      default = { };
      example = { fix-ci = { agent = "claude"; model = "sonnet"; prompt = "Fix the failing test and push a branch."; }; };
      description = "The declared environments: each runs, with a home that persists, while declared, and is deleted once not.";
    };
    labelPrefix = mkOption {
      type = types.strMatching "[a-z][a-z0-9-]*";
      default = profile.hostname;
      description = "Instance x is hostname `<prefix>-x` inside and `ssh x.<prefix>` from lenovo (jumpHosts).";
    };
    memoryMax = mkOption { type = memSize; default = "4G"; description = "Default MemoryMax of one instance."; };
    cpuQuota = mkOption { type = types.str; default = "300%"; description = "Default CPUQuota of one instance."; };
    memoryBudget = mkOption {
      type = types.nullOr memSize;
      default = null;
      description = "What all instances' memoryMax may add up to on this host; more fails eval.";
    };
    sshKey = mkOption {
      type = types.nullOr types.str;
      default = "${home}/.ssh/id_ed25519";
      description = "The host user's SSH key, bound read-only as the worker's: `git push` over SSH (url.insteadOf).";
    };
    ghHostsFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The host user's gh `hosts.yml`, bound read-only; null when the host user has no gh login.";
    };
    guestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      internal = true;
      description = "Home Manager wiring the fleet's hosts get (flake-modules/40-outputs-nixos.nix), reused in every worker.";
    };
    jumpHosts = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = { msi = "msi-ms7758"; };
      description = "Client side: `ssh <name>.<prefix>` reaches instance <name> through the worker host this maps <prefix> to.";
    };
  };

  config = lib.mkMerge [
    {
      # After the switch stopped a removed instance: its home and the stock module's per-container dirs go; a
      # still-running container (a failed stop) is left alone.
      system.activationScripts.workers = {
        deps = [ "users" ];
        text = ''
          for d in ${stateDir}/*; do
            [[ -d $d ]] || continue
            n=''${d##*/}
            case " ${lib.concatMapStringsSep " " (w: w.name) instances} " in *" $n "*) continue ;; esac
            ${config.systemd.package}/bin/systemctl is-active --quiet "container@$n.service" && continue
            rm -rf --one-file-system "$d" "/nix/var/nix/profiles/per-container/$n" "/nix/var/nix/gcroots/per-container/$n"
          done
          ${if instances == [ ] then "rmdir ${stateDir} 2>/dev/null || true" else "install -d -m 0700 ${stateDir}"}
          ${lib.concatMapStrings (w: ''
            install -d -m 0700 ${stateDir}/${w.name}
            [[ -d ${stateDir}/${w.name}/home ]] || install -d -m 0700 -o ${user} -g users ${stateDir}/${w.name}/home
          '') instances}
        '';
      };
    }

    (lib.mkIf (cfg.instances != { }) {
      assertions = map (w: {
        assertion = builtins.match "[a-z][a-z0-9-]{0,10}" w.name != null;
        message = "sam.workers.instances.${w.name}: at most 11 of [a-z0-9-], starting with a letter (its veth is ve-<name>).";
      }) instances ++ [
        {
          assertion = lib.allUnique (map (w: w.index) instances);
          message = "sam.workers.instances: two names hash to one address (10.233.<index>); rename one.";
        }
        {
          assertion = cfg.memoryBudget == null || lib.foldl' (s: w: s + toMiB w.memoryMax) 0 instances <= toMiB cfg.memoryBudget;
          message = "sam.workers.instances: their memoryMax adds up to more than this host's memoryBudget ${toString cfg.memoryBudget}.";
        }
      ];

      containers = lib.listToAttrs (map (w: lib.nameValuePair w.name {
        ephemeral = true;
        autoStart = true;
        privateNetwork = true;
        inherit (w) hostAddress;
        localAddress = w.address;
        bindMounts = {
          "${home}" = { hostPath = "${stateDir}/${w.name}/home"; isReadOnly = false; };
          "${creds}/ssh_host_ed25519_key" = { hostPath = "/etc/ssh/ssh_host_ed25519_key"; isReadOnly = true; };
        } // lib.optionalAttrs (cfg.sshKey != null) {
          "${creds}/id_ed25519" = { hostPath = cfg.sshKey; isReadOnly = true; };
          "${creds}/id_ed25519.pub" = { hostPath = "${cfg.sshKey}.pub"; isReadOnly = true; };
        } // lib.optionalAttrs (cfg.ghHostsFile != null) {
          "${creds}/gh-hosts.yml" = { hostPath = cfg.ghHostsFile; isReadOnly = true; };
        } // lib.optionalAttrs config.sam.hostSecrets.enable {
          "${creds}/claude_oauth_token" = { hostPath = config.sops.secrets.claude_oauth_token.path; isReadOnly = true; };
        };
        config = guest w;
      }) instances);

      systemd.services = lib.listToAttrs (lib.concatMap (w: [
        (lib.nameValuePair "container@${w.name}" {
          wants = [ "worker-herdr-${w.name}.service" ];
          # A changed guest (any fleet module, nixpkgs) switches live through the stock ExecReload, which runs the new
          # system's switch-to-configuration inside: the agent's ssh session keeps running.
          reloadIfChanged = true;
          partOf = [ "worker-${w.name}.service" ];
          serviceConfig = {
            MemoryMax = w.memoryMax;
            CPUQuota = w.cpuQuota;
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
        (lib.nameValuePair "worker-${w.name}" {
          description = "Declaration of nspawn worker ${w.name}";
          wantedBy = [ "machines.target" ];
          wants = [ "container@${w.name}.service" ];
          restartTriggers = [ (builtins.toJSON { inherit (w) agent model prompt memoryMax cpuQuota; }) ];
          stopIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        })
        # The instance's workspace in the host user's Herdr (the session the coordinator attaches to as a saved
        # machine), its pane running the agent; it closes when the container stops or the instance is removed.
        (lib.nameValuePair "worker-herdr-${w.name}" {
          description = "Herdr workspace of nspawn worker ${w.name}";
          bindsTo = [ "container@${w.name}.service" ];
          # after user@: on shutdown it stops first, so the Herdr server is still there to close the workspace
          after = [ "container@${w.name}.service" "user@${toString uid}.service" ];
          environment.XDG_RUNTIME_DIR = "/run/user/${toString uid}";
          # a restart would kill the running agent (its ssh): a deploy that only changes this module or pkgs.herdr
          # leaves it be, and a restart of the container brings it back
          restartIfChanged = false;
          serviceConfig = {
            # simple, not oneshot: a deploy that adds an instance does not wait for its agent to come up
            Type = "simple";
            RemainAfterExit = true;
            User = user;
            ExecStart = "${lib.getExe (hook w)} start";
            ExecStop = "${lib.getExe (hook w)} stop";
          };
        })
      ]) instances);

      # egress for the workers' 10.233.0.0/16; an address with no running worker fails at once, not on a timeout
      networking.nat = { enable = true; internalIPs = [ "10.233.0.0/16" ]; };
      networking.localCommands = "${pkgs.iproute2}/bin/ip route replace unreachable 10.233.0.0/16";
      networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

      networking.hosts = lib.listToAttrs (map (w: lib.nameValuePair w.address [ w.name "${w.name}.${cfg.labelPrefix}" ]) instances);
      # the worker presents its host's key (bound read-only), pinned under the host's name
      programs.ssh.extraConfig = lib.concatMapStrings (w: ''
        Host ${w.name} ${w.name}.${cfg.labelPrefix}
          User ${user}
          HostKeyAlias ${config.networking.hostName}
          LogLevel ERROR
      '') instances;
    })

    (lib.mkIf (cfg.jumpHosts != { }) {
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
