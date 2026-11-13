# Every value the scripts/test-*.py gates read from the hosts, in one evaluation: nixos:qa builds this once
# (GATE_PROBE), which also realises each store path a value names, and a test run on its own builds only its
# section (scripts/gate_probe.py). A section reads exactly what its test asserts on, nothing is decided here;
# a value a test checks before it would have read it is `or null`, so its check, not the probe, reports it gone.
{ root ? ./.., only ? null }:
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

  otelSurfaces = c: {
    env = (hm c).programs.claude-code.settings.env;
    codex_otel = lib.hasInfix "[otel]" (hm c).home.file.".codex/config.toml".text;
    fish_otel = lib.hasInfix "OTEL_" (toString (map (f: (hm c).programs.fish.functions.${f}) [ "claude" "codex" ]));
    # context discarded: the probe would otherwise build codex and its wrapper
    codex = map (p: builtins.mapAttrs (_: builtins.unsafeDiscardStringContext) { text = p.text or ""; path = p.outPath; })
      (builtins.filter (p: (p.pname or p.name or "") == "codex") (hm c).home.packages);
    plain_codex = builtins.unsafeDiscardStringContext hosts.lenovo.pkgs.codex.outPath;
    relay = c.systemd.services ? native-otel-relay;
    secret = c.sops.secrets ? native_otlp_auth;
  };

  rfFacts = c: {
    rfLab = (c.sam or { }) ? rfLab;
    rfLabEnabled = c.sam.rfLab.enable or false;
    k3s = c.services.k3s.enable;
    rfUnits = builtins.filter (s: builtins.match "rf-.*" s != null) (builtins.attrNames c.systemd.services);
  };

  runtimeFacts = c: {
    roles = c.sam.profile.roles;
    hostSecrets = c.sam.hostSecrets.enable;
    deployUser = c.users.users ? deploy;
    stylix = c.stylix.enable;
    hmStylix = c.home-manager.users.${c.sam.profile.username} ? stylix;
    gui = c.services.displayManager.enable || c.services.xserver.enable;
    waitSync = lib.elem "systemd-time-wait-sync.service" c.systemd.additionalUpstreamSystemUnits
      && c.systemd.services.systemd-time-wait-sync.wantedBy == [ "sysinit.target" ];
    persistent = map (t: c.systemd.timers.${t}.timerConfig.Persistent) [ "nix-gc" "nix-optimise" ]
      ++ [ c.system.autoUpgrade.persistent ];
    upgradeHooks = with c.systemd.services.nixos-upgrade; onSuccess ++ onFailure;
    upgradeAfter = c.systemd.services.nixos-upgrade.after;
    optimiseAfter = c.systemd.services.nix-optimise.after;
  };

  sections = {
    nvim-check = {
      nvim = (hm lenovo).programs.neovim.finalPackage;
      init = (hm lenovo).xdg.configFile."nvim/init.lua".text;
      nix = (hm lenovo).xdg.configFile."nvim/nix.lua".text;
    };

    native-otel-relay.helper = lenovo.systemd.services.native-otel-relay.serviceConfig.ExecStartPre;

    claude-settings = { inherit (claudeOf lenovo) home-files package; };

    coordinator-wiring = {
      inherit skills;
      files = lib.mapAttrs (_: c: builtins.attrNames (hm c).home.file) { lenovo = lenovo; acer-swift = acer; };
      local = if localNix == null then null else import (builtins.toFile "devenv.local.nix" (builtins.unsafeDiscardStringContext localNix));
      codex = lib.mapAttrs (_: c: (hm c).home.file.".codex/config.toml".text or null) { lenovo = lenovo; acer-swift = acer; };
      timers = lib.mapAttrs (_: c: (hm c).systemd.user.timers) { lenovo = lenovo; acer-swift = acer; };
      services = (hm lenovo).systemd.user.services;
      wakeup = wakeup.outPath or null;
      script = wakeup.text or null;
    };

    # the worker "host" is the guest of a probe instance declared only here (the committed config declares none)
    worker-permissions = {
      "acer-swift/probe" = claudeOf (extend "acer-swift" [ ({ lib, ... }: { sam.workers.instances = lib.mkForce { probe = { }; }; }) ]).containers.probe.config;
      lenovo = claudeOf lenovo // {
        inherit (lenovo.sam.herdr) trustedDirs;
        wakeup = (hm lenovo).systemd.user.services.coordinator-wakeup.Service.ExecStart or null;
        # the file the unit runs; toString, since ExecStart may be a list
        wakeupScript = toString ((hm lenovo).systemd.user.services.coordinator-wakeup.Service.ExecStart or "");
      };
      msi-ms7758.fish.claude = (hm msi).programs.fish.functions.claude or null;
      coordinatorAsWorker = failing (extend "lenovo" [ { sam.herdr.worker.enable = true; } ]);
    };

    ollama-portforward = {
      exe = "${hosts.lenovo.pkgs.ollama-portforward}/bin/ollama-portforward";
      unit = lenovo.systemd.user.services.ollama-portforward.serviceConfig;
    };

    known-hosts = {
      pinned = { lenovo = lenovo.programs.ssh.knownHosts; acer-swift = acer.programs.ssh.knownHosts; };
      knownHostsFile = lenovo.environment.etc."ssh/ssh_known_hosts".text;
      sshConfig = lib.mapAttrs (_: c: c.environment.etc."ssh/ssh_config".text) { lenovo = lenovo; acer-swift = acer; };
      defaults = lib.mapAttrs (_: o: o.default) { inherit (hosts.lenovo.options.sam.sshKnownHosts) strict enable; };
      sshOpts = lib.mapAttrs (_: n: n.sshOpts) (lib.getAttrs [ "lenovo" "acer-swift" "black-pi" ] flake.deploy.nodes);
    };

    build-bounds = {
      daemon = lib.mapAttrs (_: c: c.systemd.services.nix-daemon.serviceConfig or null) { lenovo = lenovo; acer-swift = acer; msi-ms7758 = msi; };
      settings = lenovo.nix.settings or null;
    };

    delegation = { inherit skills; local = localNix; };

    bulk-reader = import ./bulk-reader-probe.nix hosts // { inherit skills; };

    harness-telemetry = import ./harness-telemetry-probe.nix hosts // { inherit skills; };

    otel-rollback = {
      live = otelSurfaces lenovo;
      # acer with the same switch off: what a host without telemetry carries
      acer = (hm (extend "acer-swift" [ ({ lib, ... }: { sam.profile.nativeOtel = lib.mkForce false; }) ])).programs.claude-code.settings.env;
    };

    rf-lab-boundary.hosts = builtins.mapAttrs (_: h: rfFacts h.config) hosts;

    runtime-host = {
      hosts = lib.genAttrs [ "msi-ms7758" "acer-swift" ] (n: runtimeFacts hosts.${n}.config // { failing = failing hosts.${n}.config; });
      acerDesktop = runtimeFacts acer.specialisation.desktop.configuration;
      # the negative case: the role's own assertion must see a themed headless boot
      themed = failing (extend "msi-ms7758" [ { stylix.enable = lib.mkOverride 0 true; } ]);
    };
  };
in
{
  inherit sections;
  json = hosts.lenovo.pkgs.writeText "gate-probe.json" (builtins.toJSON (if only == null then sections else lib.getAttrs only sections));
}
