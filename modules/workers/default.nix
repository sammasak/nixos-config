# The fleet's adapter of the developer environments (core.nix, docs/nspawn-workers.md): `sam.workers.*` names, the
# fleet's guest modules and credentials, and each instance's workspace in the host's own Herdr.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers;
  dev = config.services.devEnvironments;
  profile = config.sam.profile;
  user = profile.username;
  home = "/home/${user}";
  creds = "/var/lib/host-credentials";
  usesClaude = lib.any (w: w.agent == "claude") (lib.attrValues dev.instances);
  hasToken = config.sam.hostSecrets.enable && config.sops.secrets ? claude_oauth_token;
  egress = "/run/dev-env-egress";
  egressPort = 4100;
  # The token is read from the unit's credential at request time: this file is in the store every guest reads.
  egressConfig = pkgs.writeText "dev-env-egress.Caddyfile" ''
    {
      admin off
      auto_https off
    }
    http:// {
      bind unix/${egress}/anthropic.sock
      log
      reverse_proxy https://api.anthropic.com {
        header_up Host {upstream_hostport}
        header_up Authorization "Bearer {file./run/credentials/dev-env-egress.service/claude_oauth_token}"
        header_up -X-Api-Key
        flush_interval -1
      }
    }
  '';

  agentNames = lib.attrNames (lib.filterAttrs (_: i: i.agent != "none") dev.instances);
  restartNotice = "This environment restarted: whatever you had running here, background shells and gates included, was killed and nothing restarted it. Check what finished (git status and unpushed commits in each clone), re-run what did not, and carry on; if your task was already done, say so and stop.";
  shutdownNotice = "This host powers off soon and is back at its next scheduled wake. Commit and push work in progress to a wip branch now and start no long gate; after the restart you are told to resume.";

  hook = w: pkgs.writeShellApplication {
    name = "worker-herdr-${w.name}";
    runtimeInputs = [ pkgs.coreutils pkgs.herdr pkgs.jq ];
    text = ''
      label=${w.name}
      close() {
        herdr workspace list 2>/dev/null | jq -r --arg l "$label" '.result.workspaces[]? | select(.label == $l) | .workspace_id' \
          | while read -r id; do herdr workspace close "$id" >/dev/null || true; done
      }
      # at shutdown Herdr can be gone already
      if [[ $1 == stop ]]; then close || true; exit 0; fi

      n=0
      until herdr status --json 2>/dev/null | jq -e '.server.running' >/dev/null; do
        (( ++n < 60 )) || exit 1
        sleep 1
      done
      ${w.ctl} wait || true
      mode="fresh"
      if ${w.ctl} resumable; then mode="continue"; fi
      close
      pane=$(herdr workspace create --label "$label" --no-focus | jq -er '.result.root_pane.pane_id')
      herdr pane run "$pane" "${w.ctl} attach $mode" >/dev/null
      ${lib.optionalString (w.agentDef != null) ''
        # past this point a failure must not fail the unit, or its stop (closing the workspace) never runs
        for _ in $(seq 180); do
          herdr agent list 2>/dev/null | jq -e --arg p "$pane" '.result.agents[]? | select(.pane_id == $p)' >/dev/null && break
          sleep 1
        done
        herdr agent rename "$pane" "$label" >/dev/null || echo "Herdr detected no ${w.agent} in $label" >&2
        # Herdr calls the pane idle on the host's fish prompt already; the agent takes input once it draws readyText
        if ${lib.optionalString (w.agentDef.readyText != null) ''herdr pane wait-output "$pane" --match ${lib.escapeShellArg w.agentDef.readyText} --source visible --timeout 180000 >/dev/null &&''} \
          herdr agent wait "$pane" --until idle --timeout 30000 >/dev/null; then
          # an agent that only just drew its prompt box can drop the submitting Enter, leaving the text typed
          send() {
            herdr agent prompt "$pane" "$1" --wait --until working --until "done" --timeout 15000 >/dev/null 2>&1 \
              || herdr agent send-keys "$pane" Enter >/dev/null || true
          }
          # a resumed session is a restarted agent: what it had running died with the container
          if [[ $mode == continue ]]; then
            send ${lib.escapeShellArg restartNotice}
          ${lib.optionalString (w.prompt != null) "else send ${lib.escapeShellArg w.prompt}"}
          fi
        else
          echo "${w.agent} in $label did not reach idle; see the workspace" >&2
        fi
      ''}
    '';
  };

  fleetGuest = { devEnvironment, ... }: {
    imports = [
      ../core/system.nix
      ../core/users.nix
      ../core/packages.nix
      ../core/ssh-known-hosts.nix
    ] ++ cfg.guestModules;

    # not nixpkgs.pkgs = pkgs: core/system.nix sets nixpkgs.config, which an external instance refuses
    nixpkgs.overlays = config.nixpkgs.overlays;
    sam.profile = profile // { hostname = devEnvironment.hostName; roles = [ "base" ]; pi = false; };
    sam.userConfig = config.sam.userConfig;

    environment.systemPackages = [ pkgs.time pkgs.bc ];
    # a pre-push gate runs for minutes with the connection idle, and GitHub drops it
    programs.ssh.extraConfig = "ServerAliveInterval 15\nServerAliveCountMax 200\n";
    sam.herdr.worker.enable = true;
    # Headless, reached over ssh from the host's Herdr: no session server, no firewall behind the veth, no gpg-agent
    # in front of the ssh key; the weekly repo-sweep would reclaim the agent's own clones.
    home-manager.users.${user}.systemd.user = {
      services.herdr.Install.WantedBy = lib.mkForce [ ];
      timers.repo-sweep.Install.WantedBy = lib.mkForce [ ];
      timers.nixos-config-flake-update.Install.WantedBy = lib.mkForce [ ];
    };
    programs.gnupg.agent.enable = lib.mkForce false;
    programs.dconf.enable = lib.mkForce false;
    networking.firewall.enable = false;
    sam.herdr.trustedDirs = map (d: "${home}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

    # Claude's API calls go to the host's proxy, which adds the login: the guest holds a placeholder, not the token.
    environment.variables = lib.mkIf usesClaude {
      ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString egressPort}";
      CLAUDE_CODE_OAUTH_TOKEN = "held-by-the-host";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    };
    systemd.sockets.claude-egress = { wantedBy = [ "sockets.target" ]; listenStreams = [ "127.0.0.1:${toString egressPort}" ]; };
    systemd.services.claude-egress.serviceConfig.ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${creds}/egress/anthropic.sock";

    # The host's credentials, bound read-only under ${creds}, where the host's own tools look for them.
    systemd.tmpfiles.rules = [
      "d ${home}/.ssh 0700 ${user} users -"
      "d ${home}/.config 0700 ${user} users -"
      "L+ ${home}/.ssh/id_ed25519 - - - - ${creds}/id_ed25519"
      # where the agent logs friction with the environment (docs/environments-feedback.md)
      "f ${home}/ENV-FEEDBACK.md 0644 ${user} users -"
    ]
    ++ lib.optionals (cfg.ghHostsFile != null) [
      "d ${home}/.config/gh 0700 ${user} users -"
      "L+ ${home}/.config/gh/hosts.yml - - - - ${creds}/gh-hosts.yml"
    ];
  };
in
{
  imports = [
    ./core.nix
    (lib.mkAliasOptionModule [ "sam" "workers" "instances" ] [ "services" "devEnvironments" "instances" ])
    (lib.mkAliasOptionModule [ "sam" "workers" "retired" ] [ "services" "devEnvironments" "retired" ])
    (lib.mkAliasOptionModule [ "sam" "workers" "labelPrefix" ] [ "services" "devEnvironments" "prefix" ])
    (lib.mkAliasOptionModule [ "sam" "workers" "pool" ] [ "services" "devEnvironments" "pool" ])
    (lib.mkAliasOptionModule [ "sam" "workers" "jumpHosts" ] [ "services" "devEnvironments" "jumpHosts" ])
  ];

  options.sam.workers = {
    shutdownNotice = mkOption {
      type = types.nullOr types.nonEmptyStr;
      default = null;
      example = "Mon-Fri 20:40";
      description = "A systemd calendar time, ahead of the host's scheduled poweroff, at which every agent is told to push its work.";
    };
    ghHostsFile = mkOption {
      type = types.nullOr types.externalPath;
      default = null;
      description = "The host user's gh `hosts.yml`, bound read-only; null when the host user has no gh login.";
    };
    guestModules = mkOption {
      type = types.listOf types.deferredModule;
      default = [ ];
      internal = true;
      description = "Home Manager wiring the fleet's hosts get (flake-modules/40-outputs-nixos.nix), reused in every worker.";
    };
  };

  config = {
    services.devEnvironments = {
      inherit user;
      # mutableUsers leaves the host's uid undeclared; the first normal user is allocated 1000
      uid = lib.mkIf (config.users.users.${user}.uid == null) 1000;
      shell = "fish";
      unitPrefix = "worker";
      stateDir = "/var/lib/workers";
      guestModules = [ fleetGuest ];
      credentials = {
        # the host user's own key is also the environment's, for `git push`
        id_ed25519 = dev.clientKey;
      } // lib.optionalAttrs (cfg.ghHostsFile != null) {
        "gh-hosts.yml" = cfg.ghHostsFile;
      } // lib.optionalAttrs usesClaude { inherit egress; };
      sessionSurface = { name = "herdr"; script = hook; };
    };

    systemd = lib.mkMerge [
      (lib.mkIf (cfg.shutdownNotice != null && agentNames != [ ]) {
        timers.worker-shutdown-notice = { wantedBy = [ "timers.target" ]; timerConfig.OnCalendar = cfg.shutdownNotice; };
        services.worker-shutdown-notice = {
          description = "Tell the environments' agents the host is about to power off";
          environment.XDG_RUNTIME_DIR = "/run/user/${toString dev.uid}";
          serviceConfig = { Type = "oneshot"; User = user; };
          path = [ pkgs.herdr ];
          script = lib.concatMapStrings (n: "herdr agent prompt ${n} ${lib.escapeShellArg shutdownNotice} >/dev/null || true\n") agentNames;
        };
      })
      (lib.mkIf (usesClaude && hasToken) {
        services = {
          dev-env-egress = {
            description = "Adds the Claude login to the environments' API calls";
            wantedBy = [ "multi-user.target" ];
            environment.HOME = "/tmp";
            serviceConfig = {
              ExecStart = "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${egressConfig}";
              LoadCredential = "claude_oauth_token:${config.sops.secrets.claude_oauth_token.path}";
              User = user;
              RuntimeDirectory = baseNameOf egress;
              # the guests bind this directory: removed at a restart, they would keep the old, empty one
              RuntimeDirectoryPreserve = true;
              Restart = "on-failure";
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              NoNewPrivileges = true;
            };
          };
        } // lib.genAttrs (map (n: "container@${n}") (lib.attrNames dev.instances)) (_: {
          # the bind's source must exist when the container starts
          wants = [ "dev-env-egress.service" ];
          after = [ "dev-env-egress.service" ];
        });
      })
    ];

    assertions = lib.optionals (dev.instances != { }) [
      {
        # homelab/deploy-target.nix: that key, from that host's address (a guest's traffic leaves by it), is root fleet-wide
        assertion = profile.hostname != "lenovo-21CB001PMX";
        message = "sam.workers: an instance holds the host user's SSH key, and this host's is the fleet's deploy key.";
      }
      {
        assertion = lib.all (i: i.agent != "claude" || i.credentials == null || lib.elem "egress" i.credentials) (lib.attrValues dev.instances);
        message = "sam.workers: a claude instance with a credentials subset keeps egress, the way to its login.";
      }
      {
        assertion = !usesClaude || hasToken;
        message = "sam.workers: a claude instance's calls are signed with the host's sops secret claude_oauth_token (sam.hostSecrets.enable), which this host does not declare.";
      }
      {
        assertion = config.home-manager.users.${user}.systemd.user.services ? herdr;
        message = "sam.workers: each instance's workspace lives in ${user}'s Herdr user service, which this host's Home Manager does not declare.";
      }
    ];
  };
}
