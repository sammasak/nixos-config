# llm-gateway as a host service. From the LAN lenovo reaches 8081 and black-pi's Prometheus 9091 (sam.fleet.listeners
# gateway-api and gateway-admin); Caddy reaches 8081 over loopback. Any process on acer still reaches 9091 and the
# keyless 11435 over loopback. llm-gateway.toml is the
# one deployed config: a model or provider change lands there. Without state.sqlite3 the unit is skipped, not failed, and a
# database restored after the switch needs `systemd-tmpfiles --create` (the Z rule below), then
# `systemctl start llm-gateway`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  fw = config.networking.firewall;
  state = "/var/lib/llm-gateway";
  configText = builtins.readFile ./llm-gateway.toml;
  configFile = pkgs.writeText "llm-gateway.toml" configText;
  # every key file the config names, so a provider added there needs its key in the sops file to build: the gateway
  # reads each one at startup, enabled or not
  keyFiles = lib.unique (
    lib.concatLists (
      builtins.filter builtins.isList (
        builtins.split "/run/secrets/(llm-gateway/[^\"[:space:]]+)" configText
      )
    )
  );
  # the gateway's own parse rules (llm-gateway crates/core/src/catalog.rs), checked at evaluation: a syntax error
  # throws in fromTOML, and the gateway would otherwise refuse these only at service start
  catalog = builtins.fromTOML configText;
  providers = lib.listToAttrs (
    map (p: lib.nameValuePair (p.name or "") p) (catalog.providers or [ ])
  );
  badProviders = builtins.filter (
    p:
    !(
      p ? name
      && p ? base_url
      && lib.elem (p.kind or null) [
        "gemini"
        "cloudflare"
        "ollama"
        "openai"
      ]
      && (p.kind == "ollama" || p ? api_key_file)
    )
  ) (catalog.providers or [ ]);
  badModels = builtins.filter (
    m:
    !(
      lib.all (f: m ? ${f}) [
        "provider"
        "id"
        "tier"
        "cost_class"
        "enabled"
        "context_window"
      ]
      && lib.elem m.cost_class [
        "free"
        "prepaid-capped"
        "trial-credit"
        "paid"
        "unknown"
      ]
      && providers ? ${m.provider}
      && (
        !m.enabled
        || m.cost_class == "free"
        || (m.cost_class == "prepaid-capped" && providers.${m.provider} ? billing)
      )
    )
  ) (catalog.models or [ ]);
  backup = pkgs.writers.writePython3Bin "llm-gateway-backup" { doCheck = false; } (
    builtins.readFile ./llm-gateway-backup.py
  );
in
{
  # a static user: the sops secrets need an owner at activation, before the unit runs
  users.users.llm-gateway = {
    isSystemUser = true;
    group = "llm-gateway";
  };
  users.groups.llm-gateway = { };
  sops.secrets = lib.genAttrs keyFiles (_: {
    sopsFile = ../../secrets/homelab/llm-gateway.yaml;
    owner = "llm-gateway";
    group = "llm-gateway";
    mode = "0400";
    restartUnits = [ "llm-gateway.service" ];
  });

  # Z: a migrated database keeps the pod's uid (65532) or root's, and the gateway then cannot write it
  systemd.tmpfiles.rules = [
    "d ${state} 0700 llm-gateway llm-gateway -"
    "Z ${state} - llm-gateway llm-gateway -"
  ];

  systemd.services.llm-gateway = {
    description = "llm-gateway: OpenAI-compatible routing to models that cannot bill by usage";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${state}/state.sqlite3";
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.llmGateway} ${configFile}";
      User = "llm-gateway";
      Group = "llm-gateway";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 60;
      ReadWritePaths = [ state ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      # an idle start peaks at 3.3 MB; OOMScoreAdjust below Ollama's 1000, since every caller goes through it
      MemoryMax = "256M";
      MemorySwapMax = 0;
      OOMScoreAdjust = -100;
    };
  };

  systemd.services.llm-gateway-backup = {
    description = "Back up llm-gateway's state database, with a restore check";
    unitConfig.ConditionPathExists = "${state}/state.sqlite3";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe backup} backup ${state}/state.sqlite3 /var/lib/llm-gateway-backup";
      User = "llm-gateway";
      Group = "llm-gateway";
      StateDirectory = "llm-gateway-backup";
      StateDirectoryMode = "0700";
      PrivateNetwork = true;
      ProtectSystem = "strict";
      # writable on purpose: SQLite cannot open a WAL database read-only once the gateway has shut down cleanly
      ReadWritePaths = [ state ];
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
  systemd.timers.llm-gateway-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:20:00";
      Persistent = true;
    };
  };
  environment.systemPackages = [ backup ];
  # ruff's pyflakes rules and syntax errors at build: the nightly timer would be the first to run it
  system.checks = [
    (pkgs.runCommand "llm-gateway-backup-ruff" { nativeBuildInputs = [ pkgs.ruff ]; } ''
      ruff check --isolated --no-cache --select F ${./llm-gateway-backup.py}
      touch $out
    '')
  ];

  assertions = [
    {
      assertion = lib.all (i: i == "lo") fw.trustedInterfaces;
      message = "modules/homelab/llm-gateway.nix: a trusted interface bypasses the firewall and reaches the gateway's listeners; trust only loopback, not ${toString (lib.remove "lo" fw.trustedInterfaces)}.";
    }
    {
      assertion = badProviders == [ ];
      message = "modules/homelab/llm-gateway.toml: providers ${
        toString (map (p: p.name or "<unnamed>") badProviders)
      } need name, base_url, a kind of gemini, cloudflare, ollama or openai, and api_key_file unless the kind is ollama.";
    }
    {
      assertion = badModels == [ ];
      message = "modules/homelab/llm-gateway.toml: models ${
        toString (map (m: "${m.provider or "?"}/${m.id or "?"}") badModels)
      } need provider (a declared one), id, tier, cost_class (free, prepaid-capped, trial-credit, paid or unknown), enabled and context_window; an enabled one must be free, or prepaid-capped on a provider with billing.";
    }
  ];
}
