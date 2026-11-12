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
  onGithub = i: i.egress.github.repos != [ ];
  usesGithub = lib.any onGithub (lib.attrValues dev.instances);
  # an instance's sockets: its identity to the proxy is the directory it is given
  sockets = i: lib.optional (i.agent == "claude") "anthropic" ++ lib.optional (onGithub i) "github";
  egressed = lib.filter (i: sockets i != [ ]) (lib.attrValues dev.instances);
  egress = "/run/dev-env-egress";
  guestEgress = "/run/egress";
  ports = { anthropic = 4100; github = 4102; };
  # The tokens are read at request time from the unit's credential and its private /tmp: this file is in the store
  # every guest reads.
  githubToken = "/tmp/github-token";
  site = i: s: body: ''
    http:// {
      bind unix/${egress}/${i.name}/${s}.sock
      log ${s}-${i.name}
      ${body}
    }
  '';
  anthropicSite = i: site i "anthropic" ''
    @other not path /v1/*
    respond @other 403
    reverse_proxy https://api.anthropic.com {
      header_up Host {upstream_hostport}
      header_up Authorization "Bearer {file./run/credentials/dev-env-egress.service/claude_oauth_token}"
      header_up -X-Api-Key
      flush_interval -1
    }
  '';
  upstream = url: auth: ''
    reverse_proxy ${url} {
      header_up Host {upstream_hostport}
      header_up Authorization "${auth}"
      header_up -Cookie
      flush_interval -1
    }
  '';
  # GraphQL names no repository in its path, so it cannot be held to the list: off unless asked for.
  githubSite = i: let repos = "(?i:${lib.concatMapStringsSep "|" (lib.escapeRegex) i.egress.github.repos})"; in site i "github" ''
    # what Caddy matches is the decoded path, what GitHub gets is the raw one: refuse anything they could read apart
    @odd vars_regexp {http.request.orig_uri} (?i)%(2f|5c|2e|25)|(^|/)\.\.?(/|\?|$)|//|\\
    # the owner's token administers the repository: none of that, on any listed repo
    @admin path_regexp (?i)^/repos/[^/]+/[^/]+/(rulesets|branches/.+/protection|collaborators|keys|hooks|transfer|actions/(secrets|variables|runners|permissions)|dependabot/secrets|codespaces/secrets|environments|invitations)(/.*)?$
    @adminRepo {
      path_regexp ^/repos/[^/]+/[^/]+/?$
      method PATCH PUT DELETE
    }
    handle @odd {
      respond 403
    }
    handle @admin {
      respond 403
    }
    handle @adminRepo {
      respond 403
    }
    @git {
      path_regexp ^/${repos}(\.git)?/(info/refs|git-upload-pack|git-receive-pack)$
      method GET POST
    }
    @read {
      path_regexp ^/repos/${repos}(/.*)?$
      method GET HEAD
    }
    # what an agent does to a repository: issues, comments, labels and pull requests. Merges, refs, contents,
    # workflows, releases and the rest stay off, and reviews too (an approval would be the owner's).
    @write {
      path_regexp ^/repos/${repos}/(issues(/[0-9]+(/(comments|labels|assignees))?|/comments/[0-9]+)?|pulls(/[0-9]+(/(comments|requested_reviewers))?|/comments/[0-9]+)?|labels(/[^/]+)?)/?$
      method POST PATCH
    }
    handle @git {
      ${upstream "https://github.com" "Basic {file.${githubToken}.basic}"}
    }
    handle @read {
      ${upstream "https://api.github.com" "token {file.${githubToken}}"}
    }
    handle @write {
      ${upstream "https://api.github.com" "token {file.${githubToken}}"}
    }
    ${lib.optionalString i.egress.github.graphql ''
      @graphql {
        path /graphql
        method POST
      }
      handle @graphql {
        ${upstream "https://api.github.com" "bearer {file.${githubToken}}"}
      }
    ''}
    handle {
      respond 403
    }
  '';
  egressConfig = pkgs.writeText "dev-env-egress.Caddyfile" (''
    {
      admin off
      auto_https off
    }
  '' + lib.concatMapStrings (i: lib.optionalString (i.agent == "claude") (anthropicSite i)
    + lib.optionalString (onGithub i) (githubSite i)) egressed);
  # gh keeps the token in hosts.yml (no keyring on the hosts); the proxy takes it from there at each start.
  # Without one the Claude proxy still starts, and GitHub answers 401.
  githubTokenFromHosts = pkgs.writeShellApplication {
    name = "dev-env-egress-github-token";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
    text = ''
      tok=$(awk '/^[^ ]/ { gh = $0 == "github.com:" } gh && sub(/^ +oauth_token: */, "") { print; exit }' "$CREDENTIALS_DIRECTORY/gh-hosts.yml")
      [[ -n $tok ]] || echo "no github.com oauth_token in the gh hosts.yml (a keyring login?): GitHub calls go unsigned" >&2
      umask 077
      printf '%s' "$tok" > ${githubToken}
      printf 'x-access-token:%s' "$tok" | base64 -w0 > ${githubToken}.basic
    '';
  };

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

  shim = s: {
    sockets."${s}-egress" = { wantedBy = [ "sockets.target" ]; listenStreams = [ "127.0.0.1:${toString ports.${s}}" ]; };
    services."${s}-egress".serviceConfig = { User = user; ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${guestEgress}/${s}.sock"; };
  };

  fleetGuest = { devEnvironment, ... }: let
    self = dev.instances.${devEnvironment.name};
    github = onGithub self;
  in {
    imports = [
      ../core/system.nix
      ../core/users.nix
      ../core/packages.nix
      ../core/ssh-known-hosts.nix
      ./nested-sandbox.nix
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
    home-manager.users.${user} = lib.mkMerge [
      {
        systemd.user = {
          services.herdr.Install.WantedBy = lib.mkForce [ ];
          timers.repo-sweep.Install.WantedBy = lib.mkForce [ ];
          timers.nixos-config-flake-update.Install.WantedBy = lib.mkForce [ ];
        };
      }
      (lib.mkIf github {
        # mkForce: the fleet's git sends sammasak's repos to ssh, and git applies only the longest rewrite
        programs.git.settings.url = lib.mkForce {
          "http://127.0.0.1:${toString ports.github}/".insteadOf = [ "https://github.com/" "git@github.com:" "ssh://git@github.com/" ];
        };
        xdg.configFile."gh/config.yml".text = "http_unix_socket: ${guestEgress}/github.sock\n";
      })
    ];
    programs.gnupg.agent.enable = lib.mkForce false;
    programs.dconf.enable = lib.mkForce false;
    networking.firewall.enable = false;
    sam.herdr.trustedDirs = map (d: "${home}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

    # the guest holds placeholders, not the tokens: the host's proxy adds the login to each call
    environment.variables = lib.optionalAttrs (self.agent == "claude") {
      ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString ports.anthropic}";
      CLAUDE_CODE_OAUTH_TOKEN = "held-by-the-host";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    } // lib.optionalAttrs github { GH_TOKEN = "held-by-the-host"; };

    systemd = lib.mkMerge (map (s: lib.mkIf (lib.elem s (sockets self)) (shim s)) [ "anthropic" "github" ] ++ [ { tmpfiles.rules = [
      "d ${home}/.ssh 0700 ${user} users -"
      "d ${home}/.config 0700 ${user} users -"
      # where the agent logs friction with the environment (docs/environments-feedback.md)
      "f ${home}/ENV-FEEDBACK.md 0644 ${user} users -"
    ]
    # the host's credentials, bound read-only under ${creds}, linked where the host's own tools look for them
    ++ lib.optional (!github) "L+ ${home}/.ssh/id_ed25519 - - - - ${creds}/id_ed25519"
    ++ lib.optionals (cfg.ghHostsFile != null && !github) [
      "d ${home}/.config/gh 0700 ${user} users -"
      "L+ ${home}/.config/gh/hosts.yml - - - - ${creds}/gh-hosts.yml"
    ]; } ]);
  };

  instanceModule = { config, ... }: {
    options.egress.github = {
      repos = mkOption {
        type = types.listOf (types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+");
        default = [ ];
        example = [ "sammasak/nixos-config" ];
        description = "Repositories (owner/repo) the instance reaches through the host's proxy, git and REST; non-empty, the guest holds no GitHub credential.";
      };
      graphql = mkOption { type = types.bool; default = false; description = "Also pass GitHub's GraphQL API, which no repository list can bound; most gh pr and issue commands need it."; };
    };
    config.credentials = lib.mkIf (onGithub config) (lib.subtractLists [ "id_ed25519" "gh-hosts.yml" ] (lib.attrNames dev.credentials));
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

  options.services.devEnvironments.instances = mkOption { type = types.attrsOf (types.submodule instanceModule); };

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
      };
      instanceBinds = i: lib.optionalAttrs (sockets i != [ ]) { ${guestEgress} = "${egress}/${i.name}"; };
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
      (lib.mkIf (egressed != [ ] && (!usesClaude || hasToken)) {
        services = {
          dev-env-egress = {
            description = "Adds the Claude and GitHub logins to the environments' calls";
            wantedBy = [ "multi-user.target" ];
            environment.HOME = "/tmp";
            serviceConfig = {
              ExecStart = "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${egressConfig}";
              LoadCredential = lib.optional usesClaude "claude_oauth_token:${config.sops.secrets.claude_oauth_token.path}"
                ++ lib.optional usesGithub "gh-hosts.yml:${cfg.ghHostsFile}";
              ExecStartPre = lib.mkIf usesGithub (lib.getExe githubTokenFromHosts);
              User = user;
              RuntimeDirectory = [ (baseNameOf egress) ] ++ map (i: "${baseNameOf egress}/${i.name}") egressed;
              # the guests bind this directory: removed at a restart, they would keep the old, empty one
              RuntimeDirectoryPreserve = true;
              Restart = "on-failure";
              # it parses the guests' requests as the host user: keep that user's other secrets and the guests' homes from it
              InaccessiblePaths = [ "/run/secrets.d" dev.stateDir ];
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              ProtectProc = "invisible";
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
              RestrictNamespaces = true;
              SystemCallFilter = [ "@system-service" ];
            };
          };
          # gh rewrites hosts.yml on a login or refresh; the token is read at start
          dev-env-egress-gh = lib.mkIf usesGithub {
            serviceConfig.Type = "oneshot";
            script = "${config.systemd.package}/bin/systemctl try-restart dev-env-egress.service";
          };
        } // lib.genAttrs (map (i: "container@${i.name}") egressed) (_: {
          # the bind's source must exist when the container starts
          wants = [ "dev-env-egress.service" ];
          after = [ "dev-env-egress.service" ];
        });
        paths.dev-env-egress-gh = lib.mkIf usesGithub { wantedBy = [ "multi-user.target" ]; pathConfig.PathChanged = cfg.ghHostsFile; };
      })
    ];

    # LoadCredential copies the token at start. Not on hasToken: that reads sops.secrets, which this defines.
    sops.secrets = lib.mkIf (usesClaude && config.sam.hostSecrets.enable) { claude_oauth_token.restartUnits = [ "dev-env-egress.service" ]; };

    assertions = lib.optionals (dev.instances != { }) [
      {
        # homelab/deploy-target.nix: that key, from that host's address (a guest's traffic leaves by it), is root fleet-wide
        assertion = profile.hostname != "lenovo-21CB001PMX";
        message = "sam.workers: an instance holds the host user's SSH key, and this host's is the fleet's deploy key.";
      }
      {
        assertion = !usesGithub || cfg.ghHostsFile != null;
        message = "sam.workers: an instance with egress.github.repos is signed with the token in sam.workers.ghHostsFile, which this host does not set.";
      }
      {
        assertion = lib.all (i: !onGithub i || !lib.elem "id_ed25519" i.credentials && !lib.elem "gh-hosts.yml" i.credentials) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with egress.github.repos gets neither id_ed25519 nor gh-hosts.yml.";
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
