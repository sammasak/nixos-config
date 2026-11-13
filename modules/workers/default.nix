# The fleet's adapter of the developer environments (core.nix, docs/nspawn-workers.md): `sam.workers.*` names, the
# fleet's guest modules and credentials, and each instance's workspace in the host's own Herdr.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers;
  dev = config.services.devEnvironments;
  profile = config.sam.profile;
  user = profile.username;
  inherit (dev.paths) home creds;
  onGithub = i: i.egress.github.repos != [ ];
  # The tokens are read at request time from the unit's credential and its private directory.
  githubToken = "${dev.paths.egress.private}/github-token";
  upstream = url: auth: ''
    reverse_proxy ${url} {
      header_up Host {upstream_hostport}
      header_up Authorization "${auth}"
      header_up -Cookie
      flush_interval -1
    }
  '';
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

  # validate-bash refuses force pushes; a hook skip was refused only by the deny rules a guest drops. Quoted spans
  # go first, as there, so a mention in a commit message is not a push.
  noVerifyGuard = pkgs.writeShellApplication {
    name = "no-verify-guard";
    runtimeInputs = [ pkgs.jq pkgs.gnugrep pkgs.gnused ];
    text = ''
      s=$(jq -r '.tool_input.command // ""' | sed -z "s/'[^']*'/Q/g; s/\"[^\"]*\"/Q/g")
      if grep -qE 'git[[:space:]]+([^|&;]+[[:space:]]+)?push([[:space:]][^|&;]*)?[[:space:]]--no-verify([[:space:]]|$)|git[[:space:]]+([^|&;]*[[:space:]])?-c[[:space:]]*core\.hooksPath' <<<"$s"; then
        echo "BLOCKED: a push that skips the pre-push gate (--no-verify, core.hooksPath) is not allowed in an environment." >&2
        exit 2
      fi
    '';
  };

  agentNames = lib.attrNames (lib.filterAttrs (_: i: i.agent != "none") dev.instances);
  restartNotice = "This environment restarted: whatever you had running here, background shells and gates included, was killed and nothing restarted it. Check what finished (git status and unpushed commits in each clone), re-run what did not, and carry on; if your task was already done, say so and stop.";
  shutdownNotice = "This host powers off soon and is back at its next scheduled wake. Commit and push work in progress to a wip branch now and start no long gate; after the restart you are told to resume.";

  hook = w: pkgs.writeShellApplication {
    name = "worker-herdr-${w.name}";
    runtimeInputs = [ pkgs.coreutils pkgs.herdr pkgs.jq config.systemd.package ];
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
      ${w.ctl} wait
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
          # Told once per start of the container, not per start of this unit: a retry or a restart of the surface
          # alone leaves the guest's processes alive. The marker is written after the send, so a failed run tells again.
          if [[ $mode == continue ]]; then
            inv=$(systemctl show --property=InvocationID --value container@${w.name}.service)
            if [[ -n $inv && $(cat "$XDG_RUNTIME_DIR/restart-notice-$label" 2>/dev/null) != "$inv" ]]; then
              send ${lib.escapeShellArg restartNotice}
              echo "$inv" > "$XDG_RUNTIME_DIR/restart-notice-$label"
            fi
          ${lib.optionalString (w.prompt != null) ''else send "$(< ${pkgs.writeText "${w.name}-prompt" w.prompt})"''}
          fi
        else
          echo "${w.agent} in $label did not reach idle; see the workspace" >&2
        fi
      ''}
    '';
  };

  fleetGuest = { devEnvironment, ... }: let github = onGithub dev.instances.${devEnvironment.name}; in {
    imports = [
      ../core/system.nix
      ../core/users.nix
      ../core/packages.nix
      ../core/ssh-known-hosts.nix
      ./nested-sandbox.nix
    ] ++ cfg.guestModules;

    # not nixpkgs.pkgs = pkgs: core/system.nix sets nixpkgs.config, which an external instance refuses
    # FIXME: claude-code 2.1.311 (the stable channel) in guests only, the first to read
    # CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS; drop once the pinned nixpkgs (2.1.300) carries it.
    nixpkgs.overlays = config.nixpkgs.overlays ++ [ (_: prev: { claude-code = prev.claude-code.override { manifest = {
      version = "2.1.311";
      platforms.linux-x64 = { binary = "claude.zst"; checksum = "d0c00b80761f3030f34cf0812266f6c6f8210ff9af7242f7c6c76c5600499caf"; };
    }; }; }) ];
    # nativeOtel off: the guest has neither the relay nor its secret; sam.workers.instances.<name>.telemetry is its way in
    sam.profile = profile // { hostname = devEnvironment.hostName; roles = [ "base" ]; pi = false; nativeOtel = false; };
    sam.userConfig = config.sam.userConfig;

    environment.systemPackages = [ pkgs.time pkgs.bc ];
    # a pre-push gate runs for minutes with the connection idle, and GitHub drops it
    programs.ssh.extraConfig = "ServerAliveInterval 15\nServerAliveCountMax 200\n";
    sam.herdr.worker.enable = true;
    # Headless, reached over ssh from the host's Herdr: no session server, no firewall behind the veth, no gpg-agent
    # in front of the ssh key; the weekly repo-sweep would reclaim the agent's own clones.
    home-manager.users.${user} = {
      systemd.user = {
        services.herdr.Install.WantedBy = lib.mkForce [ ];
        timers.repo-sweep.Install.WantedBy = lib.mkForce [ ];
        timers.nixos-config-flake-update.Install.WantedBy = lib.mkForce [ ];
      };
      # mkForce []: any Bash deny rule turns the variable below off. The guest is the boundary; force pushes still
      # meet validate-bash and the pre-push guard; the rest is in docs/nspawn-workers.md, Permissions.
      programs.claude-code.settings.permissions.deny = lib.mkForce [ ];
      programs.claude-code.settings.hooks.PreToolUse = [ { matcher = "Bash"; hooks = [ { type = "command"; command = lib.getExe noVerifyGuard; timeout = 15; } ]; } ];
    };
    programs.gnupg.agent.enable = lib.mkForce false;
    programs.dconf.enable = lib.mkForce false;
    networking.firewall.enable = false;
    sam.herdr.trustedDirs = map (d: "${home}/${d}") [ "claude-code-skills" "knowledge" "nixos-config" ".cache/wt" ];

    systemd.tmpfiles.rules = [
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
    ];
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
    options.telemetry = mkOption {
      type = types.bool;
      default = profile.nativeOtel;
      defaultText = lib.literalExpression "config.sam.profile.nativeOtel";
      description = "The guest's Claude Code (sam.claude.telemetry) and Codex export OTLP metrics, and Claude its events, through the proxy to this host's native-otel-relay, which needs sam.profile.nativeOtel here; the guest holds no token. The proxy's X-Otel-Worker stamp names the worker on logs only; metrics carry no worker and count under host.name.";
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
    ntfyUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "ntfy topic URL that hears of a failed environment or egress proxy, a kernel kill in the pool and a low disk; null, no alerts.";
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
        id_ed25519 = dev.paths.clientKey;
      } // lib.optionalAttrs (cfg.ghHostsFile != null) {
        "gh-hosts.yml" = cfg.ghHostsFile;
      };
      sessionSurface = { name = "herdr"; script = hook; };
      alert = lib.mkIf (cfg.ntfyUrl != null) (pkgs.writeShellScript "dev-env-alert" ''
        ${pkgs.curl}/bin/curl -fsS -m 10 -H "Title: Environment host" -H "Priority: high" -H "Tags: warning" -d "$1" ${lib.escapeShellArg cfg.ntfyUrl}
      '');
      egressInaccessible = [ "/run/secrets.d" ]; # sops-nix: every host secret; the proxy gets its own as a credential
      egress = {
        anthropic = {
          for = i: i.agent == "claude";
          site = _: ''
          @other not path /v1/*
          respond @other 403
          reverse_proxy https://api.anthropic.com {
            header_up Host {upstream_hostport}
            header_up Authorization "Bearer {file.${dev.paths.egress.credentials}/claude_oauth_token}"
            header_up -X-Api-Key
            flush_interval -1
          }
          '';
          port = 4100;
          secrets.claude_oauth_token = if config.sam.hostSecrets.enable && config.sops.secrets ? claude_oauth_token then config.sops.secrets.claude_oauth_token.path else null;
          missing = "sam.workers: a claude instance's calls are signed with the host's sops secret claude_oauth_token (sam.hostSecrets.enable), which this host does not declare.";
          guest.env = { ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString dev.egress.anthropic.port}"; CLAUDE_CODE_OAUTH_TOKEN = "held-by-the-host"; CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
            # bypassPermissions alone still stops at "Dangerous rm operation": an unattended worker would wait there
            CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS = "1"; };
        };
        github = {
          for = onGithub;
          # GraphQL names no repository in its path, so it cannot be held to the list: off unless asked for.
          site = i: let repos = "(?i:${lib.concatMapStringsSep "|" (lib.escapeRegex) i.egress.github.repos})"; in ''
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
          port = 4102;
          secrets."gh-hosts.yml" = cfg.ghHostsFile;
          missing = "sam.workers: an instance with egress.github.repos is signed with the token in sam.workers.ghHostsFile, which this host does not set.";
          prepare = [ (lib.getExe githubTokenFromHosts) ];
          guest.env.GH_TOKEN = "held-by-the-host";
          # mkForce: the fleet's git sends sammasak's repos to ssh, and git applies only the longest rewrite
          guest.config.home-manager.users.${user} = {
            programs.git.settings.url = lib.mkForce {
              "http://127.0.0.1:${toString dev.egress.github.port}/".insteadOf = [ "https://github.com/" "git@github.com:" "ssh://git@github.com/" ];
            };
            xdg.configFile."gh/config.yml".text = "http_unix_socket: ${dev.egress.github.socket}\n";
          };
        };
        # A path to the host's relay, which adds the token; the guest's Claude and Codex send to the same 127.0.0.1:4319.
        otlp = {
          for = i: i.telemetry;
          # The exact path: Caddy's path matcher ignores case and merges slashes. The relay keys its rate limit, and
          # the gateway the logs' worker.name, on the stamped header, never the guest's; metrics carry no worker.
          site = i: ''
          @other not {
            method POST
            expression `{path} in ["/v1/metrics", "/v1/logs"]`
          }
          respond @other 403
          request_header X-Otel-Worker ${i.name}
          request_body {
            max_size 1MiB
          }
          reverse_proxy http://127.0.0.1:4319
          '';
          port = 4319;
          guest.config = { devEnvironment, ... }: {
            sam.claude.telemetry = { enable = true; resourceAttributes = { "host.name" = lib.toLower profile.hostname; "worker.name" = devEnvironment.name; }; };
          };
        };
      };
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
      (lib.mkIf (lib.any onGithub (lib.attrValues dev.instances)) {
        # gh rewrites hosts.yml on a login or refresh; the token is read at start
        services.dev-env-egress-gh = {
          serviceConfig.Type = "oneshot";
          script = "${config.systemd.package}/bin/systemctl try-restart dev-env-egress.service";
        };
        paths.dev-env-egress-gh = { wantedBy = [ "multi-user.target" ]; pathConfig.PathChanged = cfg.ghHostsFile; };
      })
    ];

    # LoadCredential copies the token at start. Not on the secret's presence: that reads sops.secrets, which this defines.
    sops.secrets = lib.mkIf (lib.any dev.egress.anthropic.for (lib.attrValues dev.instances) && config.sam.hostSecrets.enable) { claude_oauth_token.restartUnits = [ "dev-env-egress.service" ]; };

    assertions = lib.optionals (dev.instances != { }) [
      {
        # homelab/deploy-target.nix: that key, from that host's address (a guest's traffic leaves by it), is root fleet-wide
        assertion = profile.hostname != config.sam.fleet.deployer;
        message = "sam.workers: an instance holds the host user's SSH key, and this host's is the fleet's deploy key.";
      }
      {
        assertion = lib.all (i: !onGithub i || !lib.elem "id_ed25519" i.credentials && !lib.elem "gh-hosts.yml" i.credentials) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with egress.github.repos gets neither id_ed25519 nor gh-hosts.yml.";
      }
      {
        assertion = profile.nativeOtel || !lib.any (i: i.telemetry) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with telemetry sends through this host's native-otel-relay, which runs only with sam.profile.nativeOtel (and the sops secret native_otlp_auth).";
      }
      {
        assertion = lib.all (i: i.paused || i.telemetry || !config.containers.${i.name}.config.sam.claude.telemetry.enable) (lib.attrValues dev.instances);
        message = "sam.workers: a guest module turned on sam.claude.telemetry, which has no relay to send to there; set sam.workers.instances.<name>.telemetry instead.";
      }
      {
        assertion = config.home-manager.users.${user}.systemd.user.services ? herdr;
        message = "sam.workers: each instance's workspace lives in ${user}'s Herdr user service, which this host's Home Manager does not declare.";
      }
    ];
  };
}
