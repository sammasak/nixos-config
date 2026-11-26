# The fleet's adapter of the developer environments (core.nix, docs/nspawn-workers.md): `sam.workers.*` names, the
# fleet's guest modules and credentials, and each instance's workspace in the host's own Herdr.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.sam.workers;
  guestClaude = "2.1.311";
  dev = config.services.devEnvironments;
  profile = config.sam.profile;
  user = profile.username;
  inherit (dev.paths) home creds;
  onGithub = i: i.egress.github.repos != [ ];
  ownRefs = i: i.egress.github.ownRefs or null != null;
  refsHeld = lib.filter ownRefs (lib.attrValues dev.instances);
  heldRepos = repoRegex (lib.unique (lib.concatMap (i: i.egress.github.repos) refsHeld));
  filterSocket = "/run/exec-pool-push-filter/filter.sock";
  # its own directory: the filter runs as the proxy's user, and node-exporter's shared one is root's
  filterMetrics = "/run/exec-pool-push-filter-metrics";
  # in the proxy's runtime directory, which no guest binds whole; no instance name starts with a dot
  pushSocket = "/run/dev-env-egress/.push.sock";
  repoRegex = repos: "(?i:${lib.concatMapStringsSep "|" (lib.escapeRegex) repos})";
  # the ref updates and a pull request's head are in the body, which Caddy cannot read: every receive-pack, and every
  # pull request creation on a listed repository, however spelled, goes to the filter, which passes the slot's own
  # task's on to the push site below
  filterRoute =
    i:
    lib.optionalString (ownRefs i) (
      "\n"
      + lib.removeSuffix "\n" ''
        @receive path_regexp (?i)git-receive-pack
        @pulls {
          path_regexp (?i)^/repos/${repoRegex i.egress.github.repos}/pulls/?$
          method POST
        }
        # msi's forward would otherwise pass another repository's to acer, which holds them to its own list alone
        @otherPulls {
          path_regexp (?i)^/repos/[^/]+/[^/]+/pulls/?$
          method POST
        }
        handle @otherPulls {
          respond 403
        }
        handle @receive {
          reverse_proxy unix/${filterSocket} {
            header_up X-Pool-Slot ${i.name}
            flush_interval -1
          }
        }
        handle @pulls {
          reverse_proxy unix/${filterSocket} {
            header_up X-Pool-Slot ${i.name}
          }
        }
      ''
    );
  # The tokens are read at request time from the unit's credential and its private directory.
  githubToken = "${dev.paths.egress.private}/github-token";
  githubRewrite."http://127.0.0.1:${toString dev.egress.github.port}/".insteadOf = [
    "https://github.com/"
    "git@github.com:"
    "ssh://git@github.com/"
  ];
  gateway = config.sam.fleet.listeners.gateway-api;
  # msi's slots reach GitHub through acer's sidecar (sam.fleet.listeners.github-egress): this host holds no token
  ghFleet = config.sam.fleet.listeners.github-egress;
  hostName = config.networking.hostName;
  ghForward = ghFleet.host != hostName && lib.elem hostName ghFleet.from;
  ghServes = ghFleet.host == hostName;
  # msi's slots' Codex through acer's route (sam.fleet.listeners.codex-egress): this host holds no login
  codexFleet = config.sam.fleet.listeners.codex-egress;
  codexForward = codexFleet.host != hostName && lib.elem hostName codexFleet.from;
  codexServes = codexFleet.host == hostName && cfg.codexEgress.serveFleet;
  fleetFrom =
    l:
    toString (
      lib.concatMap (
        h: [ config.sam.fleet.hosts.${h}.address ] ++ config.sam.fleet.hosts.${h}.extraAddresses
      ) l.from
    );
  forwardSite = ''
    reverse_proxy ${ghFleet.url} {
      header_up Host {upstream_hostport}
      flush_interval -1
    }
  '';
  oddMatcher = "@odd vars_regexp {http.request.orig_uri} (?i)%(2f|5c|2e|25)|(^|/)\\.\\.?(/|\\?|$)|//|\\\\";
  # GraphQL names no repository in its path, so it cannot be held to the list: off unless asked for.
  githubSite =
    i:
    let
      repos = repoRegex i.egress.github.repos;
    in
    ''
      # what Caddy matches is the decoded path, what GitHub gets is the raw one: refuse anything they could read apart
      ${oddMatcher}
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
      }${filterRoute i}
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
      # any other repository: a fetch alone, sent without our token, so GitHub serves only what is public
      @publicRefs {
        path_regexp ^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/info/refs$
        method GET
        expression `{query} == "service=git-upload-pack"`
      }
      @publicPack {
        path_regexp ^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/git-upload-pack$
        method POST
      }
      handle @git {
        ${upstream "https://github.com" "Basic {file.${githubToken}.basic}"}
      }
      handle @publicRefs {
        ${unsigned}
      }
      handle @publicPack {
        ${unsigned}
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
  # black-pi's monitoring APIs for homelab.execPool.monitoring, read only: the query endpoints by path and method
  # (`read` GET or POST, `get` GET alone), never an admin, write, silence or lifecycle path
  monitoring = {
    prometheus = {
      listener = config.sam.fleet.listeners.prometheus;
      port = 4105;
      env = "PROMETHEUS_URL";
      read = "^/api/v1/(query|query_range|series|labels|label/[A-Za-z0-9_.]+/values)$";
      get = "^/api/v1/(rules|alerts)$";
    };
    alertmanager = {
      listener = config.sam.fleet.listeners.alertmanager;
      port = 4106;
      env = "ALERTMANAGER_URL";
      read = null;
      get = "^/api/v2/alerts$";
    };
    # logcli reads LOKI_ADDR
    loki = {
      listener = config.sam.fleet.listeners.loki;
      port = 4107;
      env = "LOKI_ADDR";
      read = "^/loki/api/v1/(query|query_range|series)$";
      get = "^/loki/api/v1/(labels|label/[A-Za-z0-9_.]+/values)$";
    };
  };
  monitoringFrom = lib.all (m: lib.elem hostName m.listener.from) (lib.attrValues monitoring);
  # Caddy matches the decoded path and the upstream reads the raw one: an escape, dot segment or doubled slash in the
  # path is refused. The query string is passed as it is.
  monitoringSite =
    m:
    let
      proxy = ''
        reverse_proxy ${m.listener.url} {
          header_up Host {upstream_hostport}
          header_up -Authorization
          header_up -Cookie
          # black-pi serves Grafana and alerting from the same Pi: a slot's query is cut at 60 s, which cancels it
          # there, and at most two run at once per slot and service
          transport http {
            response_header_timeout 60s
            max_conns_per_host 2
          }
        }
      '';
    in
    ''
      @odd vars_regexp {http.request.orig_uri} ^[^?]*(%|//|\\|/\.\.?(/|\?|$))
      handle @odd {
        respond 403
      }
      request_body {
        max_size 1MiB
      }
      ${lib.optionalString (m.read != null) ''
        @read {
          method GET POST
          path_regexp ${m.read}
        }
        handle @read {
          ${proxy}
        }
      ''}
      @get {
        method GET
        path_regexp ${m.get}
      }
      handle @get {
        ${proxy}
      }
      handle {
        respond 403
      }
    '';
  unsigned = ''
    reverse_proxy https://github.com {
      header_up Host {upstream_hostport}
      header_up -Authorization
      header_up -Cookie
      flush_interval -1
    }
  '';
  headless = a: i: lib.elem a i.headlessAgents;
  # the hosts.nix entries with the runtime-host role, by hostName (as ssh-known-hosts.nix reads the table)
  runtimeHosts = lib.sort lib.lessThan (
    lib.mapAttrsToList (name: h: h.hostDir or name) (
      lib.filterAttrs (_: h: lib.elem "runtime-host" h.roles)
        (import ../../flake-modules/hosts.nix).configurations.nixos
    )
  );
  sameHosts = names: lib.sort lib.lessThan names == runtimeHosts;
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
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      tok=$(awk '/^[^ ]/ { gh = $0 == "github.com:" } gh && sub(/^ +oauth_token: */, "") { print; exit }' "$CREDENTIALS_DIRECTORY/gh-hosts.yml")
      [[ -n $tok ]] || echo "no github.com oauth_token in the gh hosts.yml (a keyring login?): GitHub calls go unsigned" >&2
      umask 077
      printf '%s' "$tok" > ${githubToken}
      printf 'x-access-token:%s' "$tok" | base64 -w0 > ${githubToken}.basic
    '';
  };

  inherit (cfg.codexEgress) tokens;
  # The slots' Codex, signed from sam.workers.codexAuthFile (codex-auth.nix) with what was derived from it, read per
  # request: a ChatGPT login goes to the ChatGPT backend with the client's own token and account id replaced and no
  # header added that the slot did not send; an API key to api.openai.com. A 429 (the plan's usage limit) is
  # passed through as it is: Caddy retries no POST.
  # The built-in provider cannot turn its WebSocket off: 426 sends Codex to HTTP at once (codex-rs core/src/client.rs,
  # UPGRADE_REQUIRED), where any other refusal costs it five retries first. It fetches no model list with a base_url.
  codexSite = ''
    @chatgpt file {
      root /
      try_files ${tokens}/account-id
    }
    @apikey file {
      root /
      try_files ${tokens}/openai-key
    }
    handle @chatgpt {
      ${chatgptRoute}
    }
    handle @apikey {
      @other not path /v1/*
      respond @other 403
      ${upstream "https://api.openai.com" "Bearer {file.${tokens}/openai-key}"}
    }
    handle {
      respond "codex: no Codex login in sam.workers.codexAuthFile on this host" 503
    }
  '';
  chatgptRoute = ''
    @websocket {
      path /v1/responses
      header Upgrade *
    }
    handle @websocket {
      respond 426
    }
    @responses {
      path /v1/responses
      method POST
    }
    handle @responses {
      rewrite * /backend-api/codex/responses
      reverse_proxy https://chatgpt.com {
        header_up Host {upstream_hostport}
        header_up Authorization "Bearer {file.${tokens}/access-token}"
        header_up ChatGPT-Account-ID {file.${tokens}/account-id}
        header_up -Cookie
        header_up -X-Forwarded-For
        header_up -X-Forwarded-Proto
        header_up -X-Forwarded-Host
        header_up -Via
        transport http {
          compression off
        }
        flush_interval -1
      }
    }
    handle {
      respond 403
    }
  '';

  # validate-bash refuses force pushes; a hook skip was refused only by the deny rules a guest drops. Quoted spans
  # go first, as there, so a mention in a commit message is not a push.
  noVerifyGuard = pkgs.writeShellApplication {
    name = "no-verify-guard";
    runtimeInputs = [
      pkgs.jq
      pkgs.gnugrep
      pkgs.gnused
    ];
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

  hook =
    w:
    pkgs.writeShellApplication {
      name = "worker-herdr-${w.name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.herdr
        pkgs.jq
        config.systemd.package
      ];
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
          if ${
            lib.optionalString (w.agentDef.readyText != null)
              ''herdr pane wait-output "$pane" --match ${lib.escapeShellArg w.agentDef.readyText} --source visible --timeout 180000 >/dev/null &&''
          } \
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
            ${lib.optionalString (
              w.prompt != null
            ) ''else send "$(< ${pkgs.writeText "${w.name}-prompt" w.prompt})"''}
            fi
          else
            echo "${w.agent} in $label did not reach idle; see the workspace" >&2
          fi
        ''}
      '';
    };

  fleetGuest =
    { devEnvironment, ... }@os:
    let
      bound = n: lib.elem n devEnvironment.credentials;
    in
    {
      imports = [
        ../core/system.nix
        ../core/agent-options.nix
        ../core/agent-assertions.nix
        ../core/users.nix
        ../core/packages.nix
        ../core/ssh-known-hosts.nix
        ./nested-sandbox.nix
      ]
      ++ cfg.guestModules;

      # The guest evaluates on the host's nixpkgs instance (nixpkgs.pkgs would refuse core/system.nix's nixpkgs.config
      # and re-instantiate under overlays). A guest-side nixpkgs.overlays or nixpkgs.config is ignored: the assertion
      # catches overlays; config is the host's core/system.nix.
      # claude-code guestClaude (the stable channel) in guests only, the first to read
      # CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS; an assertion below fails once the pinned nixpkgs carries it.
      _module.args.pkgs = lib.mkForce (
        pkgs
        // {
          claude-code = pkgs.claude-code.override {
            manifest = {
              version = guestClaude;
              platforms.linux-x64 = {
                binary = "claude.zst";
                checksum = "d0c00b80761f3030f34cf0812266f6c6f8210ff9af7242f7c6c76c5600499caf";
              };
            };
          };
        }
      );
      assertions = [
        {
          assertion = os.config.nixpkgs.overlays == [ ];
          message = "A worker guest shares the host's nixpkgs instance, so its nixpkgs.overlays are ignored: put overlays on the host (modules/workers/default.nix).";
        }
        {
          assertion = lib.versionOlder pkgs.claude-code.version guestClaude;
          message = "The pinned nixpkgs carries claude-code ${pkgs.claude-code.version}, at or past the guests' ${guestClaude}: drop the guest claude-code override in modules/workers/default.nix.";
        }
      ];
      # nativeOtel off: the guest has neither the relay nor its secret; sam.workers.instances.<name>.telemetry is its way in
      sam.profile = profile // {
        hostname = devEnvironment.hostName;
        roles = [ "base" ];
        pi = false;
        nativeOtel = false;
      };
      sam.userConfig = config.sam.userConfig;

      environment.systemPackages = [
        pkgs.time
        pkgs.bc
      ];
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
        programs.claude-code.settings.hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = lib.getExe noVerifyGuard;
                timeout = 15;
              }
            ];
          }
        ];
      };
      programs.gnupg.agent.enable = lib.mkForce false;
      programs.dconf.enable = lib.mkForce false;
      networking.firewall.enable = false;
      sam.herdr.trustedDirs = map (d: "${home}/${d}") [
        "claude-code-skills"
        "knowledge"
        "nixos-config"
        ".cache/wt"
      ];

      systemd.tmpfiles.rules = [
        "d ${home}/.ssh 0700 ${user} users -"
        "d ${home}/.config 0700 ${user} users -"
        # where the agent logs friction with the environment (docs/environments-feedback.md)
        "f ${home}/ENV-FEEDBACK.md 0644 ${user} users -"
      ]
      # the host's credentials bound into this guest, read-only under ${creds}, linked where the host's own tools look
      # for them: from the bound list itself, so no link can point at a credential the instance does not get
      ++ lib.optional (bound "id_ed25519") "L+ ${home}/.ssh/id_ed25519 - - - - ${creds}/id_ed25519"
      ++ lib.optionals (bound "gh-hosts.yml") [
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
      graphql = mkOption {
        type = types.bool;
        default = false;
        description = "Also pass GitHub's GraphQL API, which no repository list can bound; most gh pr and issue commands need it.";
      };
      ownRefs = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/exec-pool-runner/pool1/manifest.json";
        description = "A host file whose JSON `.task.id` names the instance's task: its git pushes then update only `refs/heads/pool/<id>` and `refs/pool-wip/<id>` (pkgs/exec-pool-push-filter), and with no such file none. Null, a push may update any ref of a listed repository.";
      };
    };
    options.egress.monitoring = mkOption {
      type = types.bool;
      default = false;
      description = "Read-only query access to black-pi's Prometheus, Alertmanager and Loki through the host's proxy, which holds the routes to sam.fleet.listeners.{prometheus,alertmanager,loki}; this host must be in each one's `from`.";
    };
    options.headlessAgents = mkOption {
      type = types.listOf (
        types.enum [
          "claude"
          "codex"
          "pi"
        ]
      );
      default = [ ];
      description = "Agents something other than the session surface starts in the instance, beside `agent`: each gets the egress route an instance with that `agent` does, and no session.";
    };
    options.telemetry = mkOption {
      type = types.bool;
      default = profile.nativeOtel;
      defaultText = lib.literalExpression "config.sam.profile.nativeOtel";
      description = "The guest's Claude Code (sam.claude.telemetry) and Codex export OTLP metrics, and Claude its events, through the proxy to this host's native-otel-relay, which needs sam.profile.nativeOtel here; the guest holds no token. The proxy's X-Otel-Worker stamp names the worker on logs and metric points.";
    };
    config.credentials = lib.mkIf (onGithub config) (
      lib.subtractLists [ "id_ed25519" "gh-hosts.yml" ] (lib.attrNames dev.credentials)
    );
  };
in
{
  imports = [
    ./core.nix
    ./execution-pool.nix
    ./codex-auth.nix
    (lib.mkAliasOptionModule
      [ "sam" "workers" "instances" ]
      [ "services" "devEnvironments" "instances" ]
    )
    (lib.mkAliasOptionModule [ "sam" "workers" "retired" ] [ "services" "devEnvironments" "retired" ])
    (lib.mkAliasOptionModule
      [ "sam" "workers" "labelPrefix" ]
      [ "services" "devEnvironments" "prefix" ]
    )
    (lib.mkAliasOptionModule [ "sam" "workers" "pool" ] [ "services" "devEnvironments" "pool" ])
    (lib.mkAliasOptionModule
      [ "sam" "workers" "jumpHosts" ]
      [ "services" "devEnvironments" "jumpHosts" ]
    )
  ];

  options.services.devEnvironments.instances = mkOption {
    type = types.attrsOf (types.submodule instanceModule);
  };

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
    codexAuthFile = mkOption {
      type = types.nullOr types.externalPath;
      default = null;
      example = "/home/alice/.codex/auth.json";
      description = "The host user's Codex `auth.json` (a ChatGPT login, or `codex login --with-api-key`), file store, which the slots' Codex calls are signed from; never bound into a guest or copied. null when the host user has no such login.";
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
      description = "Home Manager wiring the fleet's hosts get (flake-modules/nixos-configurations.nix), reused in every worker.";
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
      # the LAN's resolver, sam.fleet.public's DNS entry: msi's own resolv.conf can hold only an IPv6 RA server
      nameservers = [
        config.sam.fleet.hosts.${
          (lib.findFirst (
            p: p.port == 53 && p.host != null
          ) (throw "sam.workers: no DNS host in sam.fleet.public") config.sam.fleet.public).host
        }.address
      ];
      credentials = {
        # the host user's own key is also the environment's, for `git push`
        id_ed25519 = dev.paths.clientKey;
      }
      // lib.optionalAttrs (cfg.ghHostsFile != null) {
        "gh-hosts.yml" = cfg.ghHostsFile;
      };
      sessionSurface = {
        name = "herdr";
        script = hook;
      };
      alert = lib.mkIf (cfg.ntfyUrl != null) (
        pkgs.writeShellScript "dev-env-alert" ''
          ${pkgs.curl}/bin/curl -fsS -m 10 -H "Title: Environment host" -H "Priority: high" -H "Tags: warning" -d "$1" ${lib.escapeShellArg cfg.ntfyUrl}
        ''
      );
      records = {
        inherit (config.sam.fleet.loki) url;
        address = config.sam.fleet.hosts.${config.sam.fleet.loki.host}.address;
        # metrics/records.json's guest kinds (scripts/test-guest-records.py holds them equal): a guest never deploys,
        # records deliveries or sweeps the host's trash, so such a line from one is not shipped
        kinds = [
          "gate"
          "gate-step"
          "checks-run"
          "coverage"
          "instructions"
          "local-lane"
          "offload"
          "review"
        ];
        fleet = lib.attrNames config.sam.fleet.hosts;
      };
      egressInaccessible = [ "/run/secrets.d" ]; # sops-nix: every host secret; the proxy gets its own as a credential
      # every address, so an early start is no bind failure: the firewall admits only `from` (modules/core/network.nix),
      # and remote_ip holds the site to it too
      # the filter's upstream: a receive-pack or pull request it passed, signed here or forwarded to the fleet's sidecar
      egressSites =
        lib.optionalString (refsHeld != [ ]) ''
          http:// {
            bind unix/${pushSocket}
            log github-push
            ${oddMatcher}
            @push {
              path_regexp ^/${heldRepos}(\.git)?/git-receive-pack$
              method POST
            }
            @pulls {
              path_regexp ^/repos/${heldRepos}/pulls/?$
              method POST
            }
            handle @odd {
              respond 403
            }
            handle @push {
              ${
                if ghForward then forwardSite else upstream "https://github.com" "Basic {file.${githubToken}.basic}"
              }
            }
            handle @pulls {
              ${
                if ghForward then forwardSite else upstream "https://api.github.com" "token {file.${githubToken}}"
              }
            }
            handle {
              respond 403
            }
          }
        ''
        + lib.optionalString ghServes ''
          http://:${toString ghFleet.port} {
            log github-fleet
            @outside not remote_ip ${fleetFrom ghFleet}
            handle @outside {
              respond 403
            }
            ${githubSite {
              egress.github = {
                inherit (config.homelab.execPool) repos;
                graphql = false;
              };
            }}
          }
        ''
        + lib.optionalString codexServes ''
          http://:${toString codexFleet.port} {
            log codex-fleet
            @outside not remote_ip ${fleetFrom codexFleet}
            handle @outside {
              respond 403
            }
            ${codexSite}
          }
        '';
      egress = {
        anthropic = {
          for = i: i.agent == "claude" || headless "claude" i;
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
          secrets.claude_oauth_token =
            if config.sam.hostSecrets.enable && config.sops.secrets ? claude_oauth_token then
              config.sops.secrets.claude_oauth_token.path
            else
              null;
          missing = "sam.workers: a claude instance's calls are signed with the host's sops secret claude_oauth_token (sam.hostSecrets.enable), which this host does not declare.";
          guest.env = {
            ANTHROPIC_BASE_URL = "http://127.0.0.1:${toString dev.egress.anthropic.port}";
            CLAUDE_CODE_OAUTH_TOKEN = "held-by-the-host";
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
            # bypassPermissions alone still stops at "Dangerous rm operation": an unattended worker would wait there
            CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS = "1";
          };
        };
        github = {
          for = onGithub;
          site =
            if ghForward then
              i:
              if ownRefs i then
                lib.removePrefix "\n" (filterRoute i) + "\nhandle {\n" + forwardSite + "}\n"
              else
                forwardSite
            else
              githubSite;
          port = 4102;
          secrets = lib.optionalAttrs (!ghForward) { "gh-hosts.yml" = cfg.ghHostsFile; };
          missing = "sam.workers: an instance with egress.github.repos is signed with the token in sam.workers.ghHostsFile, which this host does not set.";
          prepare = lib.optional (!ghForward) (lib.getExe githubTokenFromHosts);
          guest.env.GH_TOKEN = "held-by-the-host";
          guest.config = {
            # also the system's: a pool attempt's HOME holds no Home Manager files, and its push URL is ssh
            programs.git = {
              enable = true;
              config.url = githubRewrite;
            };
            # mkForce: the fleet's git sends sammasak's repos to ssh, and git applies only the longest rewrite
            home-manager.users.${user} = {
              programs.git.settings.url = lib.mkForce githubRewrite;
              xdg.configFile."gh/config.yml".text = "http_unix_socket: ${dev.egress.github.socket}\n";
            };
          };
        };
        openai = {
          for = headless "codex";
          site =
            _:
            if codexForward then
              ''
                reverse_proxy ${codexFleet.url} {
                  header_up Host {upstream_hostport}
                  header_up -Authorization
                  flush_interval -1
                }
              ''
            else
              codexSite;
          port = 4103;
          missing = "sam.workers: the codex route loads no proxy credential.";
          guest.env.CODEX_API_KEY = "held-by-the-host";
          # /etc, not ~/.codex: a pool attempt runs Codex in its own, empty HOME. A custom provider, as the built-in
          # openai one speaks WebSocket to api.openai.com whatever openai_base_url says; no retries, so a 429 is asked
          # once. The web search tool (/v1/alpha/search) has no route on the ChatGPT backend, and analytics would go
          # to chatgpt.com unsigned.
          guest.config.environment.etc."codex/config.toml".text = ''
            model_provider = "host-proxy"
            web_search = "disabled"

            [model_providers.host-proxy]
            name = "OpenAI through the host proxy"
            base_url = "http://127.0.0.1:${toString dev.egress.openai.port}/v1"
            wire_api = "responses"
            env_key = "CODEX_API_KEY"
            http_headers = { version = "${pkgs.codex.version}" }
            supports_websockets = false
            request_max_retries = 0
            stream_max_retries = 0

            [analytics]
            enabled = false
          '';
        };
        # Pi's own route: the gateway holds the provider keys, the proxy the host's project key.
        llm-gateway = {
          for = headless "pi";
          site = _: ''
            @other not path /v1/*
            respond @other 403
            ${upstream gateway.url "Bearer {file.${dev.paths.egress.credentials}/llm_gateway_pi_key}"}
          '';
          port = 4104;
          secrets.llm_gateway_pi_key =
            if
              config.sops.secrets ? llm_gateway_pi_key
              && lib.elem config.networking.hostName ([ gateway.host ] ++ gateway.from)
            then
              config.sops.secrets.llm_gateway_pi_key.path
            else
              null;
          missing = "sam.workers: a pi instance's calls are signed with the sops secret llm_gateway_pi_key (sam.profile.pi) and go to sam.fleet.listeners.gateway-api, which must admit this host.";
          guest.env = {
            # a pool attempt's HOME is its own, empty one: without this Pi finds no homelab provider there
            PI_CODING_AGENT_DIR = "${home}/.pi/agent";
            PI_SKIP_VERSION_CHECK = "1";
            PI_TELEMETRY = "0";
          };
          guest.config.home-manager.users.${user} =
            { lib, ... }:
            let
              models = pkgs.writeText "pi-models.json" (
                builtins.toJSON {
                  providers.homelab = import ../programs/cli/pi/homelab-provider.nix {
                    baseUrl = "http://127.0.0.1:${toString dev.egress.llm-gateway.port}/v1";
                    apiKey = "held-by-the-host";
                  };
                }
              );
              settings = pkgs.writeText "pi-settings.json" (
                builtins.toJSON {
                  defaultProvider = "homelab";
                  defaultModel = "auto";
                  # the 32K `local` model: Pi's default 20000 kept tokens re-prefilled cold after each of 7 compactions
                  # on asus; with these, 1 (sammasak/paddock asus/ssd-expert-backing, "Pi on the pinned serve")
                  compaction = {
                    reserveTokens = 6144;
                    keepRecentTokens = 8000;
                  };
                  modelThinkingLevels."homelab/local" = "off";
                }
              );
            in
            {
              home.packages = [ pkgs.pi-coding-agent ];
              # copies, not store links: Pi rewrites its settings
              home.activation.piGateway = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
                run install -D -m 0644 ${models} "${dev.egress.llm-gateway.guest.env.PI_CODING_AGENT_DIR}/models.json"
                run install -D -m 0644 ${settings} "${dev.egress.llm-gateway.guest.env.PI_CODING_AGENT_DIR}/settings.json"
              '';
            };
        };
      }
      // lib.mapAttrs (_: m: {
        for = i: i.egress.monitoring;
        site = _: monitoringSite m;
        inherit (m) port;
        guest.env.${m.env} = "http://127.0.0.1:${toString m.port}";
      }) monitoring
      // {
        # A path to the host's relay, which adds the token; the guest's Claude and Codex send to the same 127.0.0.1:4319.
        otlp = {
          for = i: i.telemetry;
          # The exact path: Caddy's path matcher ignores case and merges slashes. The relay keys its rate limit, and
          # the gateway the worker of logs and metric points, on the stamped header, never the guest's.
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
            sam.claude.telemetry = {
              enable = true;
              resourceAttributes = {
                "host.name" = lib.toLower profile.hostname;
                "worker.name" = devEnvironment.name;
              };
            };
          };
        };
      };
    };

    services.prometheus.exporters.node.extraFlags = lib.mkIf (refsHeld != [ ]) [
      "--collector.textfile.directory=${filterMetrics}"
    ];

    systemd = lib.mkMerge [
      (lib.mkIf (cfg.shutdownNotice != null && agentNames != [ ]) {
        timers.worker-shutdown-notice = {
          wantedBy = [ "timers.target" ];
          timerConfig.OnCalendar = cfg.shutdownNotice;
        };
        services.worker-shutdown-notice = {
          description = "Tell the environments' agents the host is about to power off";
          environment.XDG_RUNTIME_DIR = "/run/user/${toString dev.uid}";
          serviceConfig = {
            Type = "oneshot";
            User = user;
          };
          path = [ pkgs.herdr ];
          enableStrictShellChecks = true;
          script = lib.concatMapStrings (
            n: "herdr agent prompt ${n} ${lib.escapeShellArg shutdownNotice} >/dev/null || true\n"
          ) agentNames;
        };
      })
      (lib.mkIf (refsHeld != [ ]) {
        # before the filter's first write: node-exporter counts a missing directory as a textfile scrape error
        tmpfiles.rules = [ "d ${filterMetrics} 0755 ${user} users -" ];
        services.exec-pool-push-filter = {
          description = "Holds the instances' git pushes to their own task's refs";
          wantedBy = [ "multi-user.target" ];
          before = [ "dev-env-egress.service" ];
          after = [ "systemd-tmpfiles-resetup.service" ];
          onFailure = lib.optional (dev.alert != null) "dev-env-alert@%n.service";
          serviceConfig = {
            ExecStart = "${
              lib.getExe (pkgs.callPackage ../../pkgs/exec-pool-push-filter/package.nix { })
            } ${filterSocket} ${pushSocket} ${
              pkgs.writeText "exec-pool-push-filter-slots.json" (
                builtins.toJSON (
                  lib.listToAttrs (map (i: lib.nameValuePair i.name i.egress.github.ownRefs) refsHeld)
                )
              )
            } ${filterMetrics}/push-filter.prom";
            # the proxy's user: each connects to the other's socket, which only its owner may
            User = user;
            RuntimeDirectory = baseNameOf (dirOf filterSocket);
            # "-": a missing directory loses the count, never the filter and so every slot's push
            ReadWritePaths = [ "-${filterMetrics}" ];
            Restart = "always";
            RestartSec = 2;
            # unix sockets on the file system only: no network of its own
            PrivateNetwork = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            InaccessiblePaths = dev.egressInaccessible ++ [ dev.stateDir ];
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ProtectProc = "invisible";
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            RestrictNamespaces = true;
            SystemCallFilter = [ "@system-service" ];
            MemoryMax = "128M";
          };
        };
      })
      (lib.mkIf (!ghForward && lib.any onGithub (lib.attrValues dev.instances)) {
        # gh rewrites hosts.yml on a login or refresh; the token is read at start
        services.dev-env-egress-gh = {
          serviceConfig.Type = "oneshot";
          enableStrictShellChecks = true;
          script = "${config.systemd.package}/bin/systemctl try-restart dev-env-egress.service";
        };
        paths.dev-env-egress-gh = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = cfg.ghHostsFile;
        };
      })
    ];

    # LoadCredential copies the token at start. Not on the secret's presence: that reads sops.secrets, which this defines.
    sops.secrets = lib.mkIf (
      lib.any dev.egress.anthropic.for (lib.attrValues dev.instances) && config.sam.hostSecrets.enable
    ) { claude_oauth_token.restartUnits = [ "dev-env-egress.service" ]; };

    assertions = [
      {
        assertion =
          config.sam.herdr.machines != [ ] -> sameHosts (map (m: m.target) config.sam.herdr.machines);
        message = "sam.herdr.machines targets ${
          toString (map (m: m.target) config.sam.herdr.machines)
        }, not the runtime hosts of flake-modules/hosts.nix (${toString runtimeHosts}): add or drop the machine.";
      }
      {
        assertion = dev.jumpHosts != { } -> sameHosts (lib.attrValues dev.jumpHosts);
        message = "sam.workers.jumpHosts names ${toString (lib.attrValues dev.jumpHosts)}, not the runtime hosts of flake-modules/hosts.nix (${toString runtimeHosts}): add or drop the jump host.";
      }
    ]
    ++ lib.optionals (dev.instances != { }) [
      {
        # modules/homelab/deploy-target.nix: that key, from that host's address (a guest's traffic leaves by it), is root fleet-wide
        assertion = profile.hostname != config.sam.fleet.deployer;
        message = "sam.workers: an instance holds the host user's SSH key, and this host's is the fleet's deploy key.";
      }
      {
        assertion = lib.all (
          i: !onGithub i || !lib.elem "id_ed25519" i.credentials && !lib.elem "gh-hosts.yml" i.credentials
        ) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with egress.github.repos gets neither id_ed25519 nor gh-hosts.yml.";
      }
      {
        assertion = lib.all (i: !(ownRefs i && i.egress.github.graphql)) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with egress.github.ownRefs opens its pull requests over REST, which the push filter reads; GraphQL's createPullRequest it cannot hold to the task.";
      }
      {
        assertion = lib.all onGithub refsHeld;
        message = "sam.workers: an instance with egress.github.ownRefs pushes through the GitHub proxy, which it reaches only with egress.github.repos.";
      }
      {
        assertion = cfg.codexEgress.serveFleet -> cfg.codexAuthFile != null && codexFleet.host == hostName;
        message = "sam.workers.codexEgress.serveFleet: this host serves sam.fleet.listeners.codex-egress, signed with its own sam.workers.codexAuthFile, so it needs that and to be the listener's host.";
      }
      {
        assertion =
          lib.any (headless "codex") (lib.attrValues dev.instances)
          -> codexForward || cfg.codexAuthFile != null;
        message = "sam.workers: a codex instance's calls are signed from the host user's Codex login in sam.workers.codexAuthFile, which this host does not set.";
      }
      {
        assertion = ghServes -> lib.any onGithub (lib.attrValues dev.instances);
        message = "sam.workers: this host serves sam.fleet.listeners.github-egress, whose token its proxy loads only for an instance of its own with egress.github.repos (homelab.execPool.repos).";
      }
      {
        assertion = monitoringFrom || !lib.any (i: i.egress.monitoring) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with egress.monitoring reads black-pi's Prometheus, Alertmanager and Loki from this host's address, which sam.fleet.listeners.{prometheus,alertmanager,loki}.from must each admit.";
      }
      {
        assertion = profile.nativeOtel || !lib.any (i: i.telemetry) (lib.attrValues dev.instances);
        message = "sam.workers: an instance with telemetry sends through this host's native-otel-relay, which runs only with sam.profile.nativeOtel (and the sops secret native_otlp_auth).";
      }
      {
        assertion = lib.all (
          i: i.paused || i.telemetry || !config.containers.${i.name}.config.sam.claude.telemetry.enable
        ) (lib.attrValues dev.instances);
        message = "sam.workers: a guest module turned on sam.claude.telemetry, which has no relay to send to there; set sam.workers.instances.<name>.telemetry instead.";
      }
      {
        assertion = config.home-manager.users.${user}.systemd.user.services ? herdr;
        message = "sam.workers: each instance's workspace lives in ${user}'s Herdr user service, which this host's Home Manager does not declare.";
      }
    ];
  };
}
