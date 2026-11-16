# Authentik and its Postgres on this host, from nixpkgs' package (unit layout after nix-community/authentik-nix's
# module.nix): Caddy (edge.nix) reaches the server and its embedded outpost on loopback; Postgres has no TCP listener
# and admits only its own superuser and authentik, by peer. The units start only on a restored database: an empty one
# would come up as a fresh install with an open akadmin setup flow. Restore: pg_restore of a latest.dump (here or
# lenovo's authentik-offhost copy) into an empty authentik database, as the authentik role.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pkg = pkgs.authentik;
  # migrate reports, and the cut-over notes, name this version; a nixpkgs bump that moves it fails the build here
  version = "2026.5.6";
  py = builtins.head pkg.worker.buildInputs;
  django = py.pkgs.authentik-django;
  pyEnv = py.withPackages (ps: [ ps.authentik-django ]);
  postgres = config.services.postgresql.package;
  fw = config.networking.firewall;
  state = "/var/lib/authentik";
  backups = "/var/lib/authentik-backup";
  pullKey = "restrict,from=\"${config.sam.fleet.hosts.lenovo-21CB001PMX.address}\",command=\"cat ${backups}/latest.dump\" ${config.programs.ssh.knownHosts.lenovo-21CB001PMX.publicKey}";
  blueprints = pkgs.symlinkJoin {
    name = "authentik-blueprints";
    paths = [
      "${django}/blueprints"
      ./authentik/blueprints
    ];
  };
  settings = {
    postgresql = {
      host = "/run/postgresql";
      name = "authentik";
      user = "authentik";
    };
    # 2026.5 defaults to [::], every interface
    listen = {
      http = [ "127.0.0.1:9000" ];
      https = [ "127.0.0.1:9443" ];
      metrics = [ "127.0.0.1:9300" ];
    };
    blueprints_dir = "${blueprints}";
    storage.file.path = state;
    cert_discovery_dir = "${state}/certs";
    error_reporting.enabled = false;
    disable_update_check = true;
    disable_startup_analytics = true;
    events.context_processors = {
      geoip = "";
      asn = "";
    };
    log_level = "info";
  };
  sopsFile = ../../secrets/homelab/authentik.yaml;
  envNames = {
    AUTHENTIK_SECRET_KEY = "authentik/secret_key";
    # the grafana blueprint reads these two by name (!Env); an unset one renders empty and blanks Grafana's client
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID = "authentik/grafana_oidc_client_id";
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = "authentik/grafana_oidc_client_secret";
  };
  # exit 1 (skipped, not failed) unless the database holds users: a deploy before the restore stays green
  restored = pkgs.writeShellScript "authentik-restored" ''
    n=$(${postgres}/bin/psql -h /run/postgresql -d authentik -tAc 'SELECT count(*) FROM authentik_core_user' 2>/dev/null) || exit 1
    [[ $n =~ ^[0-9]+$ && $n -gt 0 ]] || exit 1
  '';
  unit = extra: {
    # the target: postgresql.service is up before its ensureUsers setup has run
    after = [ "postgresql.target" ];
    requires = [ "postgresql.target" ];
    path = [ pyEnv ];
    environment.TZ = "UTC";
    serviceConfig = {
      User = "authentik";
      Group = "authentik";
      EnvironmentFile = config.sops.templates."authentik.env".path;
      ExecCondition = "${restored}";
      # the Go server and Python read ./authentik/lib/default.yml, gunicorn ./lifecycle/gunicorn.conf.py
      WorkingDirectory = "${django}";
      StateDirectory = "authentik";
      StateDirectoryMode = "0750";
      UMask = "0027";
      ProtectSystem = "strict";
      ProtectHome = true;
      # the server and the worker each bind $TMPDIR/authentik.sock: a shared /tmp would collide
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      MemorySwapMax = 0;
      # below the environment pool's guests: a dev environment goes before sign-in does
      OOMScoreAdjust = -300;
    }
    // extra;
  };
  # the dir the prometheus client shares between processes, per unit under its runtime dir
  promDir = name: {
    environment.PROMETHEUS_MULTIPROC_DIR = "/run/${name}/prometheus";
    serviceConfig = {
      RuntimeDirectory = name;
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /run/${name}/prometheus";
    };
  };
  # `sudo ak shell [-c CODE]`: upstream's lifecycle/ak (bin/ak re-splits its arguments) as the server unit runs,
  # with its user, environment and sandbox; systemd reads the env file, so no secret passes argv or the store
  ak =
    let
      server = config.systemd.services.authentik;
      props = lib.getAttrs [
        "EnvironmentFile"
        "WorkingDirectory"
        "StateDirectory"
        "StateDirectoryMode"
        "UMask"
        "ProtectSystem"
        "ProtectHome"
        "PrivateTmp"
        "NoNewPrivileges"
        "CapabilityBoundingSet"
      ] server.serviceConfig;
      # the live server's multiproc dir would collect a dead shell's metrics; lifecycle/ak picks one in the private /tmp
      env = removeAttrs server.environment [ "PROMETHEUS_MULTIPROC_DIR" ];
      arg =
        flag: n: v:
        "${flag} ${lib.escapeShellArg "${n}=${toString v}"}";
    in
    pkgs.writeShellScriptBin "ak" ''
      exec ${lib.getExe' config.systemd.package "systemd-run"} --quiet --collect --wait --pty --pipe \
        --uid=${server.serviceConfig.User} --gid=${server.serviceConfig.Group} -p MemoryMax=1G \
        ${lib.concatMapAttrsStringSep " " (arg "-p") props} \
        ${lib.concatMapAttrsStringSep " " (arg "-E") env} \
        ${pkgs.bash}/bin/bash ${django}/lifecycle/ak "$@"
    '';
in
{
  users.users.authentik = {
    isSystemUser = true;
    group = "authentik";
  };
  users.groups.authentik = { };

  environment.etc."authentik/config.yml".text = builtins.toJSON settings;
  environment.systemPackages = [ ak ];

  sops.secrets = lib.mapAttrs' (_: key: lib.nameValuePair key { inherit sopsFile; }) envNames;
  sops.templates."authentik.env" = {
    content = lib.concatStrings (
      lib.mapAttrsToList (var: key: "${var}=${config.sops.placeholder.${key}}\n") envNames
    );
    restartUnits = [
      "authentik.service"
      "authentik-worker.service"
    ];
  };

  services.postgresql = {
    enable = true;
    # the major the data was dumped from: an upgrade is its own change
    package = pkgs.postgresql_16;
    enableTCPIP = false;
    settings.listen_addresses = lib.mkForce "";
    ensureDatabases = [ "authentik" ];
    ensureUsers = [
      {
        name = "authentik";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkForce ''
      local all postgres peer
      local authentik authentik peer
    '';
  };
  systemd.services.postgresql.serviceConfig = {
    MemoryMax = "512M";
    MemorySwapMax = 0;
    OOMScoreAdjust = -300;
  };

  systemd.services.authentik-migrate =
    lib.recursiveUpdate
      (unit {
        Type = "oneshot";
        RemainAfterExit = true;
        MemoryMax = "1G";
      })
      {
        description = "Authentik database migrations";
        before = [
          "authentik-worker.service"
          "authentik.service"
        ];
        serviceConfig.ExecStart = "${pyEnv}/bin/python -m lifecycle.migrate";
      };

  systemd.services.authentik-worker =
    lib.recursiveUpdate
      (lib.recursiveUpdate (unit {
        Restart = "on-failure";
        RestartSec = 5;
        MemoryMax = "768M";
      }) (promDir "authentik-worker"))
      {
        description = "Authentik worker";
        wantedBy = [ "multi-user.target" ];
        after = [ "authentik-migrate.service" ];
        requires = [ "authentik-migrate.service" ];
        # its own listeners beside the server's; the embedded interpreter imports prometheus_client
        environment = {
          AUTHENTIK_LISTEN__HTTP = "127.0.0.1:9001";
          AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301";
          PYTHONPATH = "${pyEnv}/${py.sitePackages}";
        };
        serviceConfig.ExecStart = "${pkg.worker}/bin/authentik worker";
      };

  systemd.services.authentik =
    lib.recursiveUpdate
      (lib.recursiveUpdate (unit {
        Restart = "on-failure";
        RestartSec = 5;
        MemoryMax = "1536M";
      }) (promDir "authentik"))
      {
        description = "Authentik server and embedded outpost";
        wantedBy = [ "multi-user.target" ];
        after = [
          "authentik-migrate.service"
          "authentik-worker.service"
        ];
        requires = [ "authentik-migrate.service" ];
        serviceConfig.ExecStart = "${pkg.proxy}/bin/authentik-server";
      };

  # Nightly dump: pg_restore must read it before it replaces `latest`; lenovo pulls `latest` (authentik-offhost.nix).
  users.groups.authentik-backup = { };
  users.users.backup-pull = {
    isSystemUser = true;
    group = "authentik-backup";
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [ pullKey ];
  };
  # AllowUsers is a list the other modules extend; without this sshd refuses the pull
  services.openssh.settings.AllowUsers = [ "backup-pull" ];
  systemd.tmpfiles.rules = [
    "d ${state}/certs 0750 authentik authentik -"
    "d ${backups} 0750 postgres authentik-backup -"
  ];
  systemd.services.authentik-backup = {
    description = "Dump Authentik's database";
    after = [ "postgresql.target" ];
    requires = [ "postgresql.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "authentik-backup";
      UMask = "0027";
      ReadWritePaths = [ backups ];
      ProtectSystem = "strict";
      PrivateTmp = true;
    };
    script = ''
      set -euo pipefail
      out=${backups}/authentik-$(date +%Y%m%d-%H%M%S).dump
      ${postgres}/bin/pg_dump -h /run/postgresql -Fc -f "$out.partial" authentik
      ${postgres}/bin/pg_restore --list "$out.partial" >/dev/null
      mv "$out.partial" "$out"
      ln -sfn "$out" ${backups}/.latest.new && mv -T ${backups}/.latest.new ${backups}/latest.dump
      ls -1t ${backups}/authentik-*.dump | tail -n +8 | xargs -r rm -f
    '';
  };
  systemd.timers.authentik-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  system.checks = [
    # info-level SC2012 (ls -1t for the rotation) is the only finding below warning
    (pkgs.runCommand "authentik-backup-script-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
      shellcheck --severity=warning ${config.systemd.services.authentik-backup.serviceConfig.ExecStart}
      touch $out
    '')
    # the worker applies blueprints only after the deploy; Authentik's own parser on the directory it is given, no database
    (pkgs.runCommand "authentik-blueprints-check" { nativeBuildInputs = [ pkgs.ruff ]; } ''
      ruff check --isolated --no-cache --select F ${./authentik/check-blueprints.py}
      HOME=$TMPDIR AUTHENTIK_LOG_LEVEL=warning ${pyEnv}/bin/python -I ${./authentik/check-blueprints.py} ${blueprints}
      touch $out
    '')
  ];

  assertions = [
    {
      # the restore path: a backup that no timer starts, or a pull key another module widens, fails only when it is needed
      assertion =
        lib.elem "timers.target" config.systemd.timers.authentik-backup.wantedBy
        && config.users.users.backup-pull.openssh.authorizedKeys.keys == [ pullKey ]
        && config.users.users.backup-pull.openssh.authorizedKeys.keyFiles == [ ]
        && lib.elem "backup-pull" config.services.openssh.settings.AllowUsers;
      message = "modules/homelab/authentik.nix: authentik-backup must be started by its timer, and backup-pull must hold only lenovo's restricted key (from=, command=cat latest.dump) and be in AllowUsers.";
    }
    {
      assertion = pkg.version == version;
      message = "modules/homelab/authentik.nix: nixpkgs moved authentik to ${pkg.version}; the module and the cut-over notes are for ${version}. Bump `version` on purpose, after reading the release notes.";
    }
    {
      assertion = lib.versions.major config.services.postgresql.package.version == "16";
      message = "modules/homelab/authentik.nix: Postgres is ${config.services.postgresql.package.version}, but Authentik's data directory is major 16. Upgrade the data (dump and restore, or pg_upgrade) as its own change, then move this pin.";
    }
    {
      assertion =
        !config.services.postgresql.enableTCPIP
        && config.services.postgresql.settings.listen_addresses == ""
        &&
          lib.splitString "\n" (lib.trim config.services.postgresql.authentication) == [
            "local all postgres peer"
            "local authentik authentik peer"
          ];
      message = "modules/homelab/authentik.nix: Postgres must have no TCP listener and admit only postgres and authentik, by peer.";
    }
    {
      assertion = lib.all (l: lib.hasPrefix "127.0.0.1:" l) (
        settings.listen.http ++ settings.listen.https ++ settings.listen.metrics
      );
      message = "modules/homelab/authentik.nix: every Authentik listener stays on loopback; Caddy is the way in.";
    }
    {
      assertion = lib.all (i: i == "lo") fw.trustedInterfaces;
      message = "modules/homelab/authentik.nix: a trusted interface other than loopback reaches every port on this host.";
    }
    {
      assertion = lib.all (u: config.systemd.services.${u}.serviceConfig ? MemoryMax) [
        "authentik"
        "authentik-worker"
        "authentik-migrate"
        "postgresql"
      ];
      message = "modules/homelab/authentik.nix: every Authentik unit and Postgres carry a MemoryMax.";
    }
  ];
}
