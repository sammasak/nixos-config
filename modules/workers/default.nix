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
    ]
    ++ lib.optional hasToken "L+ /run/secrets/claude_oauth_token - - - - ${creds}/claude_oauth_token";
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
    sshKey = mkOption {
      type = types.externalPath;
      default = "${home}/.ssh/id_ed25519";
      description = "The host user's SSH key: its `.pub` lets the host's Herdr pane in, and it is the worker's own for `git push`.";
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
      clientKey = cfg.sshKey;
      unitPrefix = "worker";
      stateDir = "/var/lib/workers";
      prefix = lib.mkDefault profile.hostname;
      guestModules = [ fleetGuest ];
      credentials = {
        id_ed25519 = cfg.sshKey;
      } // lib.optionalAttrs (cfg.ghHostsFile != null) {
        "gh-hosts.yml" = cfg.ghHostsFile;
      } // lib.optionalAttrs hasToken {
        claude_oauth_token = config.sops.secrets.claude_oauth_token.path;
      };
      sessionSurface = { name = "herdr"; script = hook; };
    };

    assertions = lib.optionals (dev.instances != { }) [
      {
        assertion = !usesClaude || hasToken;
        message = "sam.workers: a claude instance logs in with the host's sops secret claude_oauth_token (sam.hostSecrets.enable), which this host does not declare.";
      }
      {
        assertion = config.home-manager.users.${user}.systemd.user.services ? herdr;
        message = "sam.workers: each instance's workspace lives in ${user}'s Herdr user service, which this host's Home Manager does not declare.";
      }
    ];
  };
}
