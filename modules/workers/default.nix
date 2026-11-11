# Ephemeral nspawn workers (docs/nspawn-workers.md): stock `containers.worker-<n>` that boot on demand
# (`systemctl start container@worker-<n>`), run Claude Code from the host's /nix/store and nix daemon, show up
# as a workspace in the host's own Herdr while they run, and leave nothing behind when stopped.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers;
  profile = config.sam.profile;
  user = profile.username;
  home = "/home/${user}";
  creds = "/var/lib/host-credentials";

  instance = n: rec {
    name = "worker-${toString n}";
    label = "${cfg.labelPrefix}-w${toString n}";
    hostAddress = "10.233.${toString n}.1";
    address = "10.233.${toString n}.2";
  };
  instances = map instance (lib.range 1 cfg.count);
  uid = if config.users.users.${user}.uid != null then config.users.users.${user}.uid else 1000;

  # The pane's foreground process is ssh, named `claude` (argv[0]) so Herdr detects a Claude agent there; its
  # status then comes from the screen and terminal title, which ssh passes through.
  session = pkgs.writeShellScript "worker-claude-session" ''
    model=()
    if [[ -n ''${2:-} ]]; then model=(--model "$2"); fi
    exec -a claude ${pkgs.openssh}/bin/ssh -tt -o HostKeyAlias=${config.networking.hostName} -o ConnectTimeout=10 \
      -o ServerAliveInterval=30 -o LogLevel=ERROR "${user}@10.233.$1.2" \
      "fish -il -c 'claude --dangerously-skip-permissions ''${model[*]}'"
  '';
  hook = pkgs.writeShellApplication {
    name = "worker-herdr";
    runtimeInputs = [ pkgs.coreutils pkgs.herdr pkgs.jq pkgs.openssh ];
    text = ''
      action=$1 n=$2 label=worker-$2
      close() {
        herdr workspace list 2>/dev/null | jq -r --arg l "$label" '.result.workspaces[]? | select(.label == $l) | .workspace_id' \
          | while read -r id; do herdr workspace close "$id" >/dev/null || true; done
      }
      if [[ $action == stop ]]; then close; exit 0; fi

      for _ in $(seq 60); do herdr status --json 2>/dev/null | jq -e '.server.running' >/dev/null && break; sleep 1; done
      for _ in $(seq 120); do
        ssh -o BatchMode=yes -o HostKeyAlias=${config.networking.hostName} -o ConnectTimeout=2 -o LogLevel=ERROR \
          "${user}@10.233.$n.2" true 2>/dev/null && break
        sleep 1
      done
      close
      pane=$(herdr workspace create --label "$label" --no-focus | jq -er '.result.root_pane.pane_id')
      model_re='^[][A-Za-z0-9._:-]+$'
      if [[ -n ''${WORKER_MODEL:-} && ! $WORKER_MODEL =~ $model_re ]]; then
        echo "ignoring WORKER_MODEL=$WORKER_MODEL" >&2; WORKER_MODEL=
      fi
      herdr pane run "$pane" "${session} $n ''${WORKER_MODEL:-}" >/dev/null
      # past this point a failure must not fail the unit, or its stop (closing the workspace) never runs
      # Herdr calls the pane idle on the host's fish prompt already; claude takes input once its footer is drawn
      if herdr pane wait-output "$pane" --match "bypass permissions on" --source visible --timeout 180000 >/dev/null \
        && herdr agent wait "$pane" --until idle --timeout 30000 >/dev/null; then
        herdr agent rename "$pane" "$label" >/dev/null || true
        # a claude that only just drew its prompt box can drop the submitting Enter, leaving the text typed
        if [[ -n ''${WORKER_PROMPT:-} ]] && ! herdr agent prompt "$pane" "$WORKER_PROMPT" --wait --until working --until "done" \
          --timeout 15000 >/dev/null 2>&1; then
          herdr agent send-keys "$pane" Enter >/dev/null || true
        fi
      else
        echo "claude in $label did not reach idle; see the workspace" >&2
      fi
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
      # the host's own key, bound read-only: stable across ephemeral boots and already pinned on the coordinator
      hostKeys = [{ path = "${creds}/ssh_host_ed25519_key"; type = "ed25519"; }];
      # the host user's own key, so the host's Herdr pane can open the worker's claude
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
in
{
  options.sam.workers = {
    count = mkOption {
      type = types.ints.between 0 200;
      default = 0;
      description = "Number of ephemeral nspawn workers `worker-1..N` this host can start.";
    };
    labelPrefix = mkOption {
      type = types.strMatching "[a-z][a-z0-9-]*";
      default = profile.hostname;
      description = "Hostname and SSH-alias prefix: worker n is `<prefix>-w<n>`.";
    };
    memoryMax = mkOption { type = types.str; default = "4G"; description = "MemoryMax of one worker (its nix builds run in the host daemon, outside it)."; };
    cpuQuota = mkOption { type = types.str; default = "300%"; description = "CPUQuota of one worker."; };
    runtimeMaxSec = mkOption { type = types.str; default = "8h"; description = "A worker left running is stopped, and so wiped, after this long."; };
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
    instances = mkOption {
      type = types.listOf types.attrs;
      readOnly = true;
      default = instances;
      description = "The workers as { name, label, address }, for the coordinator's SSH aliases.";
    };
    remotes = mkOption {
      type = types.attrsOf (types.listOf types.attrs);
      default = { };
      internal = true;
      description = "Coordinator side: each worker host's `instances`, as SSH aliases (`ssh msi-w1`) for debugging.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.count > 0) {
      containers = lib.listToAttrs (map (w: lib.nameValuePair w.name {
        ephemeral = true;
        autoStart = false;
        privateNetwork = true;
        inherit (w) hostAddress;
        localAddress = w.address;
        bindMounts = {
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

      systemd.services = lib.listToAttrs (map (w: lib.nameValuePair "container@${w.name}" {
        wants = [ "worker-herdr@${lib.removePrefix "worker-" w.name}.service" ];
        serviceConfig = {
          MemoryMax = cfg.memoryMax;
          CPUQuota = cfg.cpuQuota;
          RuntimeMaxSec = cfg.runtimeMaxSec;
        };
      }) instances) // {
        # A running worker is a workspace `worker-<n>` in the host user's Herdr (the session the coordinator
        # attaches to as a saved machine), its pane running the worker's claude; it closes when the worker stops.
        "worker-herdr@" = {
          description = "Herdr workspace of nspawn worker-%i";
          bindsTo = [ "container@worker-%i.service" ];
          # after user@: on shutdown it stops first, so the Herdr server is still there to close the workspace
          after = [ "container@worker-%i.service" "user@${toString uid}.service" ];
          environment.XDG_RUNTIME_DIR = "/run/user/${toString uid}";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = user;
            # WORKER_MODEL (claude --model) and WORKER_PROMPT (sent once claude is idle), read at every start
            EnvironmentFile = "-${home}/.config/workers/worker-%i.env";
            ExecStart = "${lib.getExe hook} start %i";
            ExecStop = "${lib.getExe hook} stop %i";
            TimeoutStartSec = "6min";
          };
        };
      };

      # egress for the workers' 10.233.0.0/16; an address with no running worker fails at once, not on a timeout
      networking.nat = { enable = true; internalIPs = [ "10.233.0.0/16" ]; };
      networking.localCommands = "${pkgs.iproute2}/bin/ip route replace unreachable 10.233.0.0/16";
      networking.networkmanager.unmanaged = [ "interface-name:ve-*" ];

      # the host user (and so the coordinator over ssh) starts and stops the workers, nothing else
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${user}"
              && /^container@worker-[0-9]+\.service$/.test(action.lookup("unit"))
              && ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0) {
            return polkit.Result.YES;
          }
        });
      '';
    })

    (lib.mkIf (cfg.remotes != { }) {
      # Through the worker host; the worker presents its host's key, checked under the host's pinned name.
      programs.ssh.extraConfig = lib.concatStrings (lib.concatLists (lib.mapAttrsToList (host: map (w: ''
        Host ${w.label}
          HostName ${w.address}
          ProxyJump ${host}
          User ${user}
          ConnectTimeout 10
          HostKeyAlias ${host}
          LogLevel ERROR
      '')) cfg.remotes));
    })
  ];
}
