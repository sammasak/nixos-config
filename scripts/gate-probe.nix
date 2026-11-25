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
  report = lib.findFirst (p: (p.name or "") == "coordinator-report") null (hm lenovo).home.packages;

  claudeOf = c: {
    inherit (hm c) home-files;
    settings = (hm c).programs.claude-code.settings;
    fish = (hm c).programs.fish.functions;
    package = (hm c).programs.claude-code.package;
    finalPackage = (hm c).programs.claude-code.finalPackage;
    activation = (hm c).home.activation.acceptClaudeStartupDialogs.data or null;
    services = builtins.attrNames (hm c).systemd.user.services;
  };

  # every sam.* and homelab.* option leaf a host declares, submodule sub-options included (named by the parent's path,
  # no attrsOf key: sam.fleet.hosts.address), with its description (null if none) and the files declaring it
  optionLeaves =
    options:
    let
      walk =
        path: opts:
        lib.concatLists (
          lib.mapAttrsToList (
            n: o:
            if lib.isOption o then
              [
                {
                  name = lib.concatStringsSep "." (path ++ [ n ]);
                  # a string, or a literalMD-style { text } from an older module
                  description =
                    let
                      d = o.description or null;
                    in
                    if d == null || builtins.isString d then d else d.text or "";
                  files = map toString o.declarations;
                }
              ]
              ++ walk (path ++ [ n ]) (
                lib.filterAttrs (k: _: !lib.hasPrefix "_" k) (o.type.getSubOptions (path ++ [ n ]))
              )
            else if builtins.isAttrs o then
              walk (path ++ [ n ]) o
            else
              [ ]
          ) opts
        );
    in
    walk [ "sam" ] (options.sam or { }) ++ walk [ "homelab" ] (options.homelab or { });

  sections = {
    # counts for the Platform health dashboard, recorded by nixos:qa (pkgs/platform-record/platform_record.py), not asserted on
    coverage = lib.mapAttrs (_: h: {
      assertions = builtins.length h.config.assertions;
      checks = builtins.length h.config.system.checks;
    }) hosts;
    # scripts/test-readability.py. Seeded: leaves without a description or with filler (blank, TODO, own name)
    option-docs = {
      hosts = lib.mapAttrs (_: h: optionLeaves h.options) hosts;
      seeded =
        optionLeaves
          (hosts.lenovo.extendModules {
            modules = [
              {
                options.sam.seededUndescribed = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                };
                options.sam.seededEmpty = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = " ";
                };
                options.sam.seededTodo = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "TODO";
                };
                options.sam.seededOwnName = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "seededOwnName";
                };
                options.homelab.seededDescribed = lib.mkOption {
                  type = lib.types.attrsOf (
                    lib.types.submodule { options.port = lib.mkOption { type = lib.types.port; }; }
                  );
                  default = { };
                  description = "Seeded: described itself, its submodule's port is not.";
                };
              }
            ];
          }).options;
    };
    # ~/.claude.json activation
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
      report = report.outPath or null;
      reportScript = report.text or null;
      failing = {
        lenovo = failing lenovo;
        acerWakeup = failing (extend "acer-swift" [ { sam.herdr.coordinatorWakeup.enable = true; } ]);
      };
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
      # what every environment's Claude starts as (modules/workers/core.nix's agents default), evaluated on acer
      agentCommand = acer.services.devEnvironments.agents.claude.command;
    };

    ollama-portforward = {
      exe = "${hosts.lenovo.pkgs.ollama-portforward}/bin/ollama-portforward";
      unit = lenovo.systemd.user.services.ollama-portforward.serviceConfig;
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
      fleet = lenovo.sam.fleet.hosts;
      failing = {
        lenovo = failing lenovo;
        unpinned = failing (
          extend "lenovo" [
            (
              { lib, ... }:
              {
                programs.ssh.knownHosts = lib.mkForce (removeAttrs lenovo.programs.ssh.knownHosts [ "asus-b460m" ]);
              }
            )
          ]
        );
        uncached = failing (
          extend "black-pi" [ ({ lib, ... }: { sam.storeCache.enable = lib.mkForce true; }) ]
        );
      };
      roles = lib.mapAttrs (_: h: h.config.sam.profile.roles) hosts;
    };

    build-bounds = {
      daemon = lib.mapAttrs (_: c: c.systemd.services.nix-daemon.serviceConfig or null) {
        lenovo = lenovo;
        acer-swift = acer;
        msi-ms7758 = msi;
      };
      settings = lenovo.nix.settings or null;
      userSlice = lenovo.systemd.slices.user.sliceConfig or null;
      memory = {
        inherit (lenovo.sam.memory) ram floors;
        systemSliceMin = lenovo.systemd.slices.system.sliceConfig.MemoryMin or null;
        floorUnits = lib.mapAttrs (_: u: u.serviceConfig.MemoryMin or null) {
          inherit (lenovo.systemd.services) adguardhome sshd;
        };
      };
      failing = {
        lenovo = failing lenovo;
        # a floor raised past what the caps leave of the RAM must fail evaluation
        overRam = failing (
          extend "lenovo" [ ({ lib, ... }: { sam.memory.floors."adguardhome.service" = lib.mkForce "1G"; }) ]
        );
      };
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
      lokiUrl = acer.sam.fleet.loki.url;
    };

    # the work-hours power windows (modules/core/power-schedule.nix): the rendered units per host and the seeded failures
    power-schedule =
      let
        fleetModule = "${flake}/modules/core/fleet.nix";
        unitsOf =
          c:
          lib.mapAttrs (_: u: u.text) (
            lib.filterAttrs (
              n: _:
              lib.hasInfix "-wake." n
              || lib.hasInfix "-scheduled-shutdown." n
              || lib.hasPrefix "wol-" n
              || lib.hasPrefix "night-quiet" n
            ) c.systemd.units
          );
      in
      {
        units = lib.mapAttrs (_: h: unitsOf h.config) hosts;
        # each host's systemd-shutdown hooks: name -> the script's store path, which the probe realises
        shutdownHooks = lib.mapAttrs (_: h: lib.mapAttrs (_: toString) h.config.systemd.shutdown) hosts;
        fleet = lib.mapAttrs (_: h: { inherit (h) sleeps power quiet; }) lenovo.sam.fleet.hosts;
        inherit (lenovo.sam.fleet) night;
        failing = {
          lenovo = failing lenovo;
          msi = failing msi;
          asus = failing hosts.asus-b460m.config;
          sleepingWaker = failing (extend "msi-ms7758" [ { sam.powerSchedule.waker.enable = true; } ]);
          noWol = failing (
            extend "asus-b460m" [
              ({ lib, ... }: { networking.interfaces.eno1.wakeOnLan.enable = lib.mkForce false; })
            ]
          );
          # a quiet host whose kernel would not run intel_pstate
          quietNoPstate = failing (
            extend "acer-swift" [ { boot.kernelParams = [ "intel_pstate=disable" ]; } ]
          );
          # fleet.nix is read-only: these seeds swap it for a copy, msi both windowed and quiet, black-pi quiet
          quietWithWindow = failing (
            extend "lenovo" [
              {
                disabledModules = [ fleetModule ];
                imports = [
                  (
                    args:
                    let
                      m = import fleetModule args;
                    in
                    m
                    // {
                      config = lib.recursiveUpdate m.config {
                        sam.fleet.hosts.msi-ms7758.quiet = {
                          driver = "intel_pstate";
                          maxPerfPct = 60;
                        };
                      };
                    }
                  )
                ];
              }
            ]
          );
          quietPi = failing (
            extend "black-pi" [
              {
                disabledModules = [ fleetModule ];
                imports = [
                  (
                    args:
                    let
                      m = import fleetModule args;
                    in
                    m
                    // {
                      config = lib.recursiveUpdate m.config {
                        sam.fleet.hosts.black-pi.quiet = {
                          driver = "intel_pstate";
                          maxPerfPct = 60;
                        };
                      };
                    }
                  )
                ];
              }
            ]
          );
          # fleet.nix is read-only, so the seed swaps the module for a copy whose asus entry is awake
          awake = failing (
            extend "lenovo" [
              {
                disabledModules = [ fleetModule ];
                imports = [
                  (
                    args:
                    let
                      m = import fleetModule args;
                    in
                    m // { config = lib.recursiveUpdate m.config { sam.fleet.hosts.asus-b460m.sleeps = false; }; }
                  )
                ];
              }
            ]
          );
        };
      };

    # the dual-boot towers' GRUB (modules/hardware/windows-dual-boot.nix): the Windows entry and the ESP assertion's seeds
    dual-boot = {
      grub = lib.mapAttrs (_: h: {
        inherit (h.config.boot.loader.grub) enable extraEntries mirroredBoots;
        systemdBoot = h.config.boot.loader.systemd-boot.enable;
      }) hosts;
      failing = {
        msi = failing msi;
        asus = failing hosts.asus-b460m.config;
        notVfat = failing (
          extend "msi-ms7758" [ ({ lib, ... }: { fileSystems."/boot".fsType = lib.mkForce "ext4"; }) ]
        );
        noMount = failing (
          extend "asus-b460m" [
            (
              { lib, ... }:
              {
                boot.loader.grub.mirroredBoots = lib.mkOverride 10 [
                  {
                    path = "/boot-nix";
                    efiSysMountPoint = "/efi";
                    devices = [ "nodev" ];
                  }
                ];
              }
            )
          ]
        );
      };
    };

    # lenovo's AdGuard (modules/homelab/adguardhome.nix, nixos-config#503): what it answers the LAN from, and the seeds
    adguard-dns = {
      hostsfile = lenovo.services.adguardhome.settings.dns.hostsfile_enabled or null;
      rewrites = map (r: {
        inherit (r) domain answer;
      }) lenovo.services.adguardhome.settings.filtering.rewrites;
      fleet = lib.mapAttrs (_: h: h.address) lenovo.sam.fleet.hosts;
      failing = {
        lenovo = failing lenovo;
        hostsfileOn = failing (
          extend "lenovo" [
            ({ lib, ... }: { services.adguardhome.settings.dns.hostsfile_enabled = lib.mkForce true; })
          ]
        );
        loopbackRewrite = failing (
          extend "lenovo" [
            {
              homelab.dns.rewrites = [
                {
                  domain = "acer-swift";
                  answer = "127.0.0.2";
                }
              ];
            }
          ]
        );
      };
    };

    # acer's Caddyfile as deployed (realised, so caddy fmt has run) and the Caddy that runs it
    # acer's slots' Codex on the owner's ChatGPT login (modules/workers/codex-login.nix): the proxy's route, the helpers
    # the test runs against stubs, and every place a slot's environment could name the login
    codex-egress =
      let
        svc = acer.systemd.services;
        slots = lib.filter (lib.hasPrefix "pool") (builtins.attrNames acer.containers);
      in
      {
        caddyfile = lib.last (lib.splitString " " svc.dev-env-egress.serviceConfig.ExecStart);
        egress = { inherit (svc.dev-env-egress.serviceConfig) User LoadCredential; };
        login = {
          inherit (acer.sam.workers.codexLogin)
            enable
            home
            tokens
            loginCommand
            ;
        };
        derive = svc.codex-egress-token.serviceConfig.ExecStart;
        path = acer.systemd.paths.codex-egress-token.pathConfig;
        refresh = {
          inherit (svc.codex-egress-refresh) environment;
          inherit (svc.codex-egress-refresh.serviceConfig) ExecStart;
          timer = acer.systemd.timers.codex-egress-refresh.timerConfig;
        };
        runner = {
          inherit (svc.exec-pool-runner-pool1.serviceConfig) ExecStart;
          inherit (svc.exec-pool-runner-pool1.environment) EXEC_POOL_SLOT;
        };
        inherit (acer.homelab.execPool) agents;
        slots = lib.genAttrs slots (
          n:
          let
            g = acer.containers.${n}.config;
          in
          {
            binds = acer.containers.${n}.bindMounts;
            unit = svc."container@${n}".environment;
            inherit (g.environment) variables sessionVariables;
            services = lib.mapAttrs (_: u: u.environment) g.systemd.services;
            codexConfig = (hm g).home.file.".codex/config.toml".text;
          }
        );
        exec = svc."exec-pool-exec@".environment;
        # turned on: acer serves the listener, msi's slots offer codex
        fleet =
          let
            a = extend "acer-swift" [ { sam.workers.codexLogin.serveFleet = true; } ];
            m = extend "msi-ms7758" [ { homelab.execPool.agents = [ "codex" ]; } ];
            caddy = c: lib.last (lib.splitString " " c.systemd.services.dev-env-egress.serviceConfig.ExecStart);
          in
          {
            listener = { inherit (m.sam.fleet.listeners.codex-egress) host port url; };
            acer = caddy a;
            msi = caddy m;
            msiAddress = a.sam.fleet.hosts.msi-ms7758.address;
            msiCreds = m.systemd.services.dev-env-egress.serviceConfig.LoadCredential;
            failing = {
              acer = failing a;
              msi = failing m;
            };
          };
        offCaddy = lib.last (
          lib.splitString " " msi.systemd.services.dev-env-egress.serviceConfig.ExecStart
        );
        failing = {
          acer = failing acer;
          withKey = failing (
            extend "acer-swift" [ { sam.workers.codexAuthFile = "/home/lukas/.codex/auth.json"; } ]
          );
          serveWithout = failing (
            extend "acer-swift" [
              (
                { lib, ... }:
                {
                  sam.workers.codexLogin.enable = lib.mkForce false;
                  sam.workers.codexLogin.serveFleet = true;
                }
              )
            ]
          );
        };
      };

    caddy-edge = {
      caddy = lib.getExe acer.services.caddy.package;
      inherit (acer.services.caddy) configFile enableReload;
      sites = {
        herman = "${hosts.acer-swift.pkgs.hermanWeb}";
      };
      chatStreams = acer.systemd.sockets.open-webui-proxy.listenStreams;
      fleet = lib.mapAttrs (_: h: h.address) acer.sam.fleet.hosts;
      ntfyPort = acer.sam.fleet.ntfy.port;
      edgeMetrics = {
        address = acer.sam.fleet.hosts.${acer.sam.fleet.edgeMetrics.host}.address;
        inherit (acer.sam.fleet.edgeMetrics) port;
      };
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

    # asus's CUDA Ollama as deployed, and the seeded cases: the same host without hardware.graphics, and with
    # graphics but no NVIDIA library in the drivers env (its gpu check as a .drv, context discarded: the seed must
    # fail in the test, not in the probe's build)
    ollama-gpu =
      let
        gpuCheck =
          c:
          builtins.unsafeDiscardStringContext (
            (lib.findFirst (d: d.name == "asus-ollama-gpu-check") null c.system.checks).drvPath or ""
          );
      in
      {
        failing = {
          asus = failing hosts.asus-b460m.config;
          powerHigh = failing (
            extend "asus-b460m" [ ({ lib, ... }: { homelab.ollama.gpuPowerLimit = lib.mkForce 271; }) ]
          );
          powerLow = failing (
            extend "asus-b460m" [ ({ lib, ... }: { homelab.ollama.gpuPowerLimit = lib.mkForce 99; }) ]
          );
          ctx2k = failing (
            extend "asus-b460m" [
              ({ lib, ... }: { services.ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH = lib.mkForce "2048"; })
            ]
          );
          ctx64k = failing (
            extend "asus-b460m" [
              ({ lib, ... }: {
                services.ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH = lib.mkForce "65536";
              })
            ]
          );
          cacheAtCap = failing (
            extend "asus-b460m" [ ({ lib, ... }: { homelab.ollama.promptCacheMiB = lib.mkForce 8192; }) ]
          );
          noGraphics = failing (
            extend "asus-b460m" [ ({ lib, ... }: { hardware.graphics.enable = lib.mkForce false; }) ]
          );
        };
        powerUnit = {
          inherit (hosts.asus-b460m.config.systemd.services.nvidia-power-limit)
            wantedBy
            before
            after
            requiredBy
            ;
          inherit (hosts.asus-b460m.config.systemd.services.nvidia-power-limit.serviceConfig) Type;
          # the path only: with its context the probe would realise asus's nvidia-x11 on every gate host (#502)
          ExecStart = builtins.unsafeDiscardStringContext hosts.asus-b460m.config.systemd.services.nvidia-power-limit.serviceConfig.ExecStart;
          timeout =
            hosts.asus-b460m.config.systemd.services.nvidia-power-limit.serviceConfig.TimeoutStartSec or null;
          persistenced = hosts.asus-b460m.config.hardware.nvidia.nvidiaPersistenced;
          remain =
            hosts.asus-b460m.config.systemd.services.nvidia-power-limit.serviceConfig.RemainAfterExit or false;
          ollamaRequires = hosts.asus-b460m.config.systemd.services.ollama.requires;
          ollamaBindsTo = hosts.asus-b460m.config.systemd.services.ollama.bindsTo;
        };
        check = {
          asus = gpuCheck hosts.asus-b460m.config;
          noNvidiaLibs = gpuCheck (
            extend "asus-b460m" [ ({ lib, ... }: { hardware.graphics.extraPackages = lib.mkForce [ ]; }) ]
          );
        };
      };

    # acer's ak wrapper and the server unit environment it copies
    authentik = {
      ak = lib.findFirst (p: (p.name or "") == "ak") null acer.environment.systemPackages;
      envKeys = builtins.attrNames acer.systemd.services.authentik.environment;
    };

    # scripts/test-shunt-metrics.py: lenovo and acer (with its guests) run it, msi imports it off; context discarded
    shunt-metrics =
      let
        facts =
          c:
          builtins.fromJSON (
            builtins.unsafeDiscardStringContext (
              builtins.toJSON {
                flags = c.services.prometheus.exporters.node.extraFlags;
                tmpfiles = c.systemd.tmpfiles.rules;
                service = c.systemd.services.shunt-metrics.serviceConfig or null;
                environment = c.systemd.services.shunt-metrics.environment or null;
                timer = c.systemd.timers.shunt-metrics.timerConfig or null;
                failing = failing c;
                stateDir = c.services.devEnvironments.stateDir;
                # per declared guest: its unit's command and timer, its declared switch and whether its Claude
                # settings register the shunt Read hook
                guests = lib.mapAttrs (n: _: {
                  exec = c.systemd.services."shunt-metrics-guest-${n}".serviceConfig.ExecStart or null;
                  timer = c.systemd.timers."shunt-metrics-guest-${n}".timerConfig or null;
                  declared = c.containers.${n}.config.sam.claude.bulkReader.enable;
                  readHook = lib.any (e: e.matcher or "" == "Read") (
                    (hm c.containers.${n}.config).programs.claude-code.settings.hooks.PreToolUse or [ ]
                  );
                }) c.services.devEnvironments.instances;
              }
            )
          );
      in
      {
        enabled = lib.mapAttrs (_: h: h.config.homelab.shuntMetrics.enable or false) hosts;
        imported = lib.mapAttrs (_: h: h.options ? homelab.shuntMetrics) hosts;
        username = lenovo.sam.profile.username;
        on = facts lenovo;
        acer = facts acer;
        off = facts msi;
        offDevTools = failing (
          # the flake's copy: black-pi imports node-exporter.nix from it, and a second path declares its options twice
          extend "black-pi" [
            "${flake}/modules/homelab/shunt-metrics.nix"
            { homelab.shuntMetrics.enable = true; }
          ]
        );
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
                hostName = c.networking.hostName;
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
        deployNodes = builtins.attrNames flake.deploy.nodes;
        # the negative case: the hosts check must see the module enabled on naked-pi, the one host without it
        seeded = facts (
          extend "naked-pi" [
            ../modules/homelab/journal-collector.nix
            {
              homelab.journalCollector = {
                enable = true;
                lokiUrl = "http://loki.example/loki/api/v1/push";
              };
            }
          ]
        );
      };

    # each paging unit's script and sam.workers.ntfyUrl on every host, pi-ticket's wrapper on the Pi hosts with the
    # gateway listener, and the seeded cases: acer without the runtime-host role's sam.workers.ntfyUrl, Loki and the
    # collector on naked-pi with no URL set, an empty URL, ntfy off its fleet host and a host redefining a fleet fact;
    # context discarded: nothing here needs a build
    fleet-endpoints =
      let
        pages =
          c:
          builtins.fromJSON (
            builtins.unsafeDiscardStringContext (
              builtins.toJSON (
                lib.filterAttrs (_: v: v != null) (
                  lib.genAttrs [ "caddy-failed" "journal-collector-failed" "loki-failed" ] (
                    n: c.systemd.services.${n}.script or null
                  )
                )
                // {
                  workers = c.sam.workers.ntfyUrl;
                }
              )
            )
          );
        evaluates = x: (builtins.tryEval (builtins.deepSeq x x)).success;
        collector = extra: [
          ../modules/homelab/journal-collector.nix
          {
            homelab.journalCollector = {
              enable = true;
            }
            // extra;
          }
        ];
      in
      {
        inherit (acer.sam.fleet) pageUrl;
        ntfyAddress = acer.sam.fleet.hosts.${acer.sam.fleet.ntfy.host}.address;
        inherit (acer.sam.fleet.ntfy) port;
        hosts = lib.mapAttrs (_: h: pages h.config) hosts;
        # pi-ticket's wrapper text on every sam.profile.pi host, and the gateway listener it must name
        piTicket = lib.mapAttrs (
          _: h:
          builtins.unsafeDiscardStringContext (
            (lib.findFirst (p: (p.name or "") == "pi-ticket") { } (hm h.config).home.packages).text or ""
          )
        ) (lib.filterAttrs (_: h: h.config.sam.profile.pi) hosts);
        gatewayApi = {
          inherit (acer.sam.fleet.listeners.gateway-api) url host port;
          address = acer.sam.fleet.hosts.${acer.sam.fleet.listeners.gateway-api.host}.address;
        };
        gatewayAdmin = {
          inherit (acer.sam.fleet.listeners.gateway-admin)
            url
            host
            port
            from
            ;
          address = acer.sam.fleet.hosts.${acer.sam.fleet.listeners.gateway-admin.host}.address;
        };
        seeded = {
          acerWithoutWorkersUrl = pages (
            extend "acer-swift" [ ({ lib, ... }: { sam.workers.ntfyUrl = lib.mkForce null; }) ]
          );
          nakedPi = pages (
            extend "naked-pi" (
              collector { }
              ++ [
                ../modules/homelab/loki.nix
                { homelab.loki.enable = true; }
              ]
            )
          );
          emptyUrl = evaluates (
            (extend "naked-pi" (collector {
              ntfyUrl = "";
            })).systemd.services.journal-collector-failed.script
          );
          ntfyOffHost = failing (
            extend "acer-swift" [
              ../modules/homelab/ntfy.nix
              {
                homelab.ntfy = {
                  enable = true;
                  baseUrl = "https://ntfy.example";
                };
              }
            ]
          );
          fleetRedefined =
            evaluates
              (extend "naked-pi" [ { sam.fleet.ntfy.port = 2587; } ]).sam.fleet.pageUrl;
        };
      };

    # the fleet's ports (scripts/test-fleet-contract.py scans the tree for them), every host's rendered firewall
    # against the sam.fleet listeners and public entries, the port each listener's service binds, and the seeded
    # cases: a port off its fleet fact, an opening the facts do not list, lenovo's machines or jump hosts off the
    # runtime hosts of hosts.nix, a collector on a host without a fleet address
    fleet-contract =
      let
        blackPi = hosts.black-pi.config;
        inherit (lenovo.sam) herdr;
        inherit (lenovo.sam.fleet) listeners;
        ports = i: {
          inherit (i)
            allowedTCPPorts
            allowedUDPPorts
            allowedTCPPortRanges
            allowedUDPPortRanges
            ;
        };
      in
      {
        ports = {
          ntfy = lenovo.sam.fleet.ntfy.port;
          loki = lenovo.sam.fleet.loki.port;
        };
        # pkgs/platform-record/platform_record.py's default Loki, run without Nix, is checked against this
        lokiUrl = lenovo.sam.fleet.loki.url;
        listeners = lib.mapAttrs (_: l: {
          inherit (l)
            host
            port
            proto
            from
            ;
        }) listeners;
        inherit (lenovo.sam.fleet) public lanCidr;
        firewall = lib.mapAttrs' (
          _: h:
          let
            fw = h.config.networking.firewall;
          in
          lib.nameValuePair h.config.networking.hostName (
            ports fw
            // {
              inherit (fw)
                enable
                backend
                extraCommands
                extraInputRules
                trustedInterfaces
                ;
              interfaces = lib.mapAttrs (_: ports) fw.interfaces;
            }
          )
        ) hosts;
        # what the services bind, a drift check: each takes its port from its listener, so a new listener needs no
        # entry here (scripts/test-fleet-contract.py); the gateway's toml is asserted in llm-gateway.nix
        bound = {
          alertmanager = blackPi.services.prometheus.alertmanager.port;
          # the metrics server's virtual host, http://:<port> (edge.nix)
          edge-metrics = lib.head (
            lib.concatLists (
              lib.filter (m: m != null) (
                map (builtins.match "http://:([0-9]+)") (lib.attrNames acer.services.caddy.virtualHosts)
              )
            )
          );
          prometheus = blackPi.services.prometheus.port;
          grafana = blackPi.services.grafana.settings.server.http_port;
          loki = blackPi.homelab.loki.port;
          ollama-msi = msi.services.ollama.port;
          ollama-asus = hosts.asus-b460m.config.services.ollama.port;
          exec-pool-db = acer.services.postgresql.settings.port;
          alloy-http = lib.head (
            builtins.match ".*--server[.]http[.]listen-addr=[^ ]*:([0-9]+).*" (
              builtins.unsafeDiscardStringContext acer.systemd.services.alloy-otlp.serviceConfig.ExecStart
            )
          );
        }
        // lib.mapAttrs' (
          _: h:
          lib.nameValuePair "node-exporter-${h.config.networking.hostName}" h.config.services.prometheus.exporters.node.port
        ) (removeAttrs hosts [ "naked-pi" ])
        # the GPU hosts' exporters (gpu-exporter.nix, on where sam.fleet says gpu)
        // lib.mapAttrs' (
          _: h:
          lib.nameValuePair "nvidia-gpu-${h.config.networking.hostName}" h.config.services.prometheus.exporters.nvidia-gpu.port
        ) (lib.filterAttrs (_: h: h.config.homelab.gpuTelemetry.enable or false) hosts)
        # harmonia's bind, [::]:<port>, on each host that serves a store cache (store-cache.nix)
        // lib.mapAttrs' (
          _: h:
          lib.nameValuePair "store-cache-${h.config.networking.hostName}" (
            lib.last (lib.splitString ":" h.config.services.harmonia.cache.settings.bind)
          )
        ) (lib.filterAttrs (_: h: h.config.sam.storeCache.enable) hosts);
        addresses = lib.mapAttrs (_: h: [ h.address ] ++ h.extraAddresses) lenovo.sam.fleet.hosts;
        machines = map (m: m.target) herdr.machines;
        jumpHosts = lenovo.services.devEnvironments.jumpHosts;
        failing = {
          hosts = lib.mapAttrs (_: h: failing h.config) hosts;
          lenovo = failing lenovo;
          blackPi = failing blackPi;
          openPort = failing (extend "acer-swift" [ { networking.firewall.allowedTCPPorts = [ 9999 ]; } ]);
          upstreamOpen = failing (
            extend "msi-ms7758" [ { services.prometheus.exporters.node.openFirewall = true; } ]
          );
          strayRule = failing (
            extend "lenovo" [
              {
                networking.firewall.extraCommands = "iptables -w -A nixos-fw -s 192.168.10.50 -p tcp --dport 9100 -j nixos-fw-accept";
              }
            ]
          );
          trusted = failing (extend "black-pi" [ { networking.firewall.trustedInterfaces = [ "eth0" ]; } ]);
          lokiAnySource = failing (
            extend "black-pi" [ { networking.firewall.allowedTCPPorts = [ lenovo.sam.fleet.loki.port ]; } ]
          );
          ntfyElsewhere = failing (
            extend "msi-ms7758" [
              ../modules/homelab/ntfy.nix
              {
                homelab.ntfy = {
                  enable = true;
                  baseUrl = "https://ntfy.example";
                };
              }
            ]
          );
          lokiLoopback = failing (
            extend "black-pi" [ ({ lib, ... }: { homelab.loki.listenAddress = lib.mkForce "127.0.0.1"; }) ]
          );
          ntfyPort = failing (extend "lenovo" [ ({ lib, ... }: { homelab.ntfy.port = lib.mkForce 2587; }) ]);
          lokiPort = failing (
            extend "black-pi" [ ({ lib, ... }: { homelab.loki.port = lib.mkForce 3101; }) ]
          );
          machineForgotten = failing (
            extend "lenovo" [
              (
                { lib, ... }:
                {
                  sam.herdr.machines = lib.mkForce (lib.filter (m: m.target != "asus-b460m") herdr.machines);
                }
              )
            ]
          );
          jumpHostRemoved = failing (extend "lenovo" [ { sam.workers.jumpHosts.old = "old-host"; } ]);
          exporterOffFleet = failing (extend "naked-pi" [ ../modules/homelab/monitoring/node-exporter.nix ]);
          collectorOffFleet = failing (
            extend "naked-pi" [
              ../modules/homelab/journal-collector.nix
              { homelab.journalCollector.enable = true; }
            ]
          );
        };
      };
  };
in
{
  inherit sections;
  json = hosts.lenovo.pkgs.writeText "gate-probe.json" (
    builtins.toJSON (if only == null then sections else lib.getAttrs only sections)
  );
}
