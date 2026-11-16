# Every value the scripts/test-*.py gates read from the hosts, in one evaluation: nixos:qa builds this once
# (GATE_PROBE), which also realises each store path a value names, and a test run on its own builds only its
# section (scripts/gate_probe.py). A section reads exactly what its test asserts on, nothing is decided here;
# a value a test checks before it would have read it is `or null`, so its check, not the probe, reports it gone.
{
  root ? ./..,
  only ? null,
}:
let
  flake = builtins.getFlake (toString root);
  inherit (flake.inputs.nixpkgs) lib;
  hosts = flake.nixosConfigurations;
  lenovo = hosts.lenovo.config;
  acer = hosts.acer-swift.config;
  msi = hosts.msi-ms7758.config;
  hm = c: c.home-manager.users.lukas;
  failing = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  extend = host: modules: (hosts.${host}.extendModules { inherit modules; }).config;
  localNix = (hm lenovo).home.file."claude-code-skills/devenv.local.nix".text or null;
  skills = flake.inputs.skills.outPath;
  wakeup = lib.findFirst (p: (p.name or "") == "coordinator-wakeup") null (hm lenovo).home.packages;

  claudeOf = c: {
    inherit (hm c) home-files;
    settings = (hm c).programs.claude-code.settings;
    fish = (hm c).programs.fish.functions;
    package = (hm c).programs.claude-code.package;
    finalPackage = (hm c).programs.claude-code.finalPackage;
    activation = (hm c).home.activation.acceptClaudeStartupDialogs.data or null;
    services = builtins.attrNames (hm c).systemd.user.services;
  };

  sections = {
    # ~/.claude.json activation
    # counts for the Platform health dashboard, recorded by nixos:qa (scripts/platform-record.sh), not asserted on
    coverage = lib.mapAttrs (_: h: {
      assertions = builtins.length h.config.assertions;
      checks = builtins.length h.config.system.checks;
    }) hosts;
    switch-safety = {
      claudeActivation = (hm lenovo).home.activation.acceptClaudeStartupDialogs.data;
    };

    nvim-check = {
      nvim = (hm lenovo).programs.neovim.finalPackage;
      init = (hm lenovo).xdg.configFile."nvim/init.lua".text;
      nix = (hm lenovo).xdg.configFile."nvim/nix.lua".text;
    };

    native-otel-relay.helper = lenovo.systemd.services.native-otel-relay.serviceConfig.ExecStartPre;

    claude-settings = { inherit (claudeOf lenovo) home-files package; };

    coordinator-wiring = {
      inherit skills;
      files = lib.mapAttrs (_: c: builtins.attrNames (hm c).home.file) {
        lenovo = lenovo;
        acer-swift = acer;
      };
      local =
        if localNix == null then
          null
        else
          import (builtins.toFile "devenv.local.nix" (builtins.unsafeDiscardStringContext localNix));
      codex = lib.mapAttrs (_: c: (hm c).home.file.".codex/config.toml".text or null) {
        lenovo = lenovo;
        acer-swift = acer;
      };
      timers = lib.mapAttrs (_: c: (hm c).systemd.user.timers) {
        lenovo = lenovo;
        acer-swift = acer;
      };
      services = (hm lenovo).systemd.user.services;
      wakeup = wakeup.outPath or null;
      script = wakeup.text or null;
    };

    # the worker "host" is the guest of a probe instance declared only here (the committed config declares none)
    worker-permissions = {
      "acer-swift/probe" =
        claudeOf
          (extend "acer-swift" [ ({ lib, ... }: { sam.workers.instances = lib.mkForce { probe = { }; }; }) ])
          .containers.probe.config;
      lenovo = claudeOf lenovo // {
        inherit (lenovo.sam.herdr) trustedDirs;
        wakeup = (hm lenovo).systemd.user.services.coordinator-wakeup.Service.ExecStart or null;
        # the file the unit runs; toString, since ExecStart may be a list
        wakeupScript = toString (
          (hm lenovo).systemd.user.services.coordinator-wakeup.Service.ExecStart or ""
        );
      };
      msi-ms7758.fish.claude = (hm msi).programs.fish.functions.claude or null;
    };

    ollama-portforward = {
      exe = "${hosts.lenovo.pkgs.ollama-portforward}/bin/ollama-portforward";
      unit = lenovo.systemd.user.services.ollama-portforward.serviceConfig;
    };

    alert-bridge = {
      units = builtins.mapAttrs (_: h: h.config.systemd.services ? alert-bridge) hosts;
      inherit (lenovo.systemd.services.alert-bridge) environment serviceConfig;
      ntfyListen = lenovo.services.ntfy-sh.settings.listen-http;
      ntfyUnit = {
        inherit (lenovo.systemd.services.ntfy-sh) startLimitIntervalSec;
        inherit (lenovo.systemd.services.ntfy-sh.serviceConfig) Restart;
      };
      firewall = {
        open = lenovo.networking.firewall.allowedTCPPorts;
        rules = lenovo.networking.firewall.extraCommands;
      };
      inherit (lenovo.sam.fleet) lanCidr;
      failing = {
        lenovo = failing lenovo;
        loopbackFirewall = failing (
          extend "lenovo" [ ({ lib, ... }: { homelab.alertBridge.listenAddress = lib.mkForce "127.0.0.1"; }) ]
        );
        noNtfy = failing (extend "lenovo" [ ({ lib, ... }: { homelab.ntfy.enable = lib.mkForce false; }) ]);
      };
      httpsUrl =
        (builtins.tryEval
          (extend "lenovo" [
            ({ lib, ... }: { homelab.alertBridge.ntfyUrl = lib.mkForce "https://ntfy.example/x"; })
          ]).systemd.services.alert-bridge.environment.ALERT_BRIDGE_NTFY_URL
        ).success;
    };

    known-hosts = {
      pinned = {
        lenovo = lenovo.programs.ssh.knownHosts;
        acer-swift = acer.programs.ssh.knownHosts;
      };
      knownHostsFile = lenovo.environment.etc."ssh/ssh_known_hosts".text;
      sshConfig = lib.mapAttrs (_: c: c.environment.etc."ssh/ssh_config".text) {
        lenovo = lenovo;
        acer-swift = acer;
      };
      sshOpts = lib.mapAttrs (_: n: n.sshOpts) (
        lib.getAttrs [ "lenovo" "acer-swift" "black-pi" ] flake.deploy.nodes
      );
      # each declared sops secret's file, repo-relative, and the identities sops-nix decrypts with
      sops =
        let
          files =
            c: lib.mapAttrs (_: s: lib.removePrefix "${flake.outPath}/" (toString s.sopsFile)) c.sops.secrets;
        in
        {
          hosts = builtins.mapAttrs (_: h: {
            inherit (h.config.networking) hostName;
            files = files h.config;
            keys = lib.mapAttrs (_: s: { inherit (s) key format; }) h.config.sops.secrets;
            age = { inherit (h.config.sops.age) sshKeyPaths keyFile generateKey; };
            gnupg = { inherit (h.config.sops.gnupg) home sshKeyPaths; };
          }) hosts;
          # re-seed if black-pi becomes a recipient of claude/native-otlp-auth.yaml or turns nativeOtel on
          seeded = files (
            extend "black-pi" [ ({ lib, ... }: { sam.profile.nativeOtel = lib.mkForce true; }) ]
          );
        };
      deployNodes = builtins.attrNames flake.deploy.nodes;
    };

    build-bounds = {
      daemon = lib.mapAttrs (_: c: c.systemd.services.nix-daemon.serviceConfig or null) {
        lenovo = lenovo;
        acer-swift = acer;
        msi-ms7758 = msi;
      };
      settings = lenovo.nix.settings or null;
      userSlice = lenovo.systemd.slices.user.sliceConfig or null;
    };

    delegation = {
      inherit skills;
      local = localNix;
    };

    bulk-reader = import ./bulk-reader-probe.nix hosts // {
      inherit skills;
    };

    harness-telemetry = import ./harness-telemetry-probe.nix hosts // {
      inherit skills;
    };

    # acer's unit as deployed: its ExecStart realises acer's Alloy, the wrapper and the rendered config; Loki is
    # black-pi's version from an x86 package set (lenovo's, the same nixpkgs)
    alloy-otlp = {
      execStart = acer.systemd.services.alloy-otlp.serviceConfig.ExecStart or null;
      loki = "${hosts.lenovo.pkgs.grafana-loki}/bin/loki";
    };

    # acer's Caddyfile as deployed (realised, so caddy fmt has run) and the Caddy that runs it
    caddy-edge = {
      caddy = lib.getExe acer.services.caddy.package;
      inherit (acer.services.caddy) configFile enableReload;
      sites = {
        herman = "${hosts.acer-swift.pkgs.hermanWeb}";
      };
      chatStreams = acer.systemd.sockets.open-webui-proxy.listenStreams;
      fleet = lib.mapAttrs (_: h: h.address) acer.sam.fleet.hosts;
      # what lenovo's AdGuard answers for the names, and what black-pi's blackbox probes
      rewrites = lenovo.homelab.dns.rewrites;
      prometheusConfig = hosts.black-pi.config.services.prometheus.configText;
      cert = { inherit (acer.security.acme.certs."sammasak.dev") directory extraDomainNames; };
      failing = {
        acer = failing acer;
        noCaddy = failing (
          extend "acer-swift" [ ({ lib, ... }: { services.caddy.enable = lib.mkForce false; }) ]
        );
      };
    };

    # acer's ak wrapper and the server unit environment it copies
    authentik = {
      ak = lib.findFirst (p: (p.name or "") == "ak") null acer.environment.systemPackages;
      envKeys = builtins.attrNames acer.systemd.services.authentik.environment;
    };

    # every host, so a collector enabled anywhere else is seen; context discarded: nothing here needs a build
    journal-collector =
      let
        facts =
          c:
          builtins.fromJSON (
            builtins.unsafeDiscardStringContext (
              builtins.toJSON {
                enable = c.homelab.journalCollector.enable or false;
                alloy = c.services.alloy.enable;
                config = c.services.alloy.configPath.text or null;
                execStart = c.systemd.services.alloy.serviceConfig.ExecStart or null;
                checks = map (d: d.name) c.system.checks;
                flags = c.services.alloy.extraFlags;
                environmentFile = c.services.alloy.environmentFile;
                unit = lib.genAttrs [ "onFailure" "startLimitIntervalSec" "startLimitBurst" ] (
                  n: c.systemd.services.alloy.${n} or null
                );
                configPath = c.services.alloy.configPath;
                service = lib.genAttrs [
                  "ExecStartPost"
                  "TimeoutStartSec"
                  "MemoryMax"
                  "RestartSec"
                  "LoadCredential"
                  "EnvironmentFile"
                ] (n: c.systemd.services.alloy.serviceConfig.${n} or null);
                failed = c.systemd.services.journal-collector-failed.script or null;
              }
            )
          );
      in
      {
        hosts = lib.mapAttrs (_: h: facts h.config) hosts;
        # the negative case: the msi-only check must see the module enabled on acer
        seeded = facts (
          extend "acer-swift" [
            ../modules/homelab/journal-collector.nix
            {
              homelab.journalCollector = {
                enable = true;
                lokiUrl = "http://loki.example:3100/loki/api/v1/push";
              };
            }
          ]
        );
      };
  };
in
{
  inherit sections;
  json = hosts.lenovo.pkgs.writeText "gate-probe.json" (
    builtins.toJSON (if only == null then sections else lib.getAttrs only sections)
  );
}
