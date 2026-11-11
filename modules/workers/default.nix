# Ephemeral nspawn workers (docs/nspawn-workers.md): stock `containers.worker-<n>` that boot on demand
# (`systemctl start container@worker-<n>`), run Claude Code under Herdr from the host's /nix/store and nix
# daemon, and leave nothing behind when stopped. The coordinator reaches them through the host (ProxyJump).
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
    users.users.${user}.uid = if config.users.users.${user}.uid != null then config.users.users.${user}.uid else 1000;
    networking.hostName = w.label;
    programs.fish.enable = true;

    sam.herdr.worker.enable = true;
    sam.herdr.trustedDirs = map (d: "${home}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

    services.openssh = {
      enable = true;
      startWhenNeeded = false;
      # the host's own key, bound read-only: stable across ephemeral boots and already pinned on the coordinator
      hostKeys = [{ path = "${creds}/ssh_host_ed25519_key"; type = "ed25519"; }];
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
      description = "Herdr label and hostname prefix: worker n is `<prefix>-w<n>`.";
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
      description = "The workers as { name, label, address }, for the coordinator.";
    };
    remotes = mkOption {
      type = types.attrsOf (types.listOf types.attrs);
      default = { };
      internal = true;
      description = "Coordinator side: each worker host's `instances`, saved as Herdr machines behind SSH aliases.";
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
        } // lib.optionalAttrs (cfg.ghHostsFile != null) {
          "${creds}/gh-hosts.yml" = { hostPath = cfg.ghHostsFile; isReadOnly = true; };
        } // lib.optionalAttrs config.sam.hostSecrets.enable {
          "${creds}/claude_oauth_token" = { hostPath = config.sops.secrets.claude_oauth_token.path; isReadOnly = true; };
        };
        config = guest w;
      }) instances);

      systemd.services = lib.listToAttrs (map (w: lib.nameValuePair "container@${w.name}" {
        serviceConfig = {
          MemoryMax = cfg.memoryMax;
          CPUQuota = cfg.cpuQuota;
          RuntimeMaxSec = cfg.runtimeMaxSec;
        };
      }) instances);

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
      # Not in sam.herdr.machines: a worker is saved in Herdr when it starts (`herdr machine add`) and removed when
      # it stops, so a stopped worker never sits in the sidebar.
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
