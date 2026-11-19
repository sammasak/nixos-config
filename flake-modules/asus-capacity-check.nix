# A two-slot candidate is explicit and bounded; baseline power, context, residency and memory policy stay intact.
{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.asus-b460m;
  baseline = host.config;
  trial =
    (host.extendModules {
      modules = [ { homelab.ollama.parallelRequests = 2; } ];
    }).config;
  invalid = builtins.tryEval (
    builtins.deepSeq
      (host.extendModules {
        modules = [ { homelab.ollama.parallelRequests = 3; } ];
      }).config.homelab.ollama.parallelRequests
      true
  );
  bypass =
    (host.extendModules {
      modules = [ { services.ollama.environmentVariables.OLLAMA_NUM_PARALLEL = lib.mkForce "3"; } ];
    }).config;
  snapshot = c: {
    powerLimit = c.homelab.ollama.gpuPowerLimit;
    context = c.services.ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH;
    loadedModels = c.services.ollama.environmentVariables.OLLAMA_MAX_LOADED_MODELS;
    flashAttention = c.services.ollama.environmentVariables.OLLAMA_FLASH_ATTENTION;
    kvCache = c.services.ollama.environmentVariables.OLLAMA_KV_CACHE_TYPE;
    memoryMax = c.systemd.services.ollama.serviceConfig.MemoryMax;
    modelPins = c.homelab.ollama.modelDigests;
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.asus-trial-preflight =
        pkgs.runCommand "asus-trial-preflight"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.ruff
            ];
          }
          ''
            ruff check --isolated --no-cache --select F ${../scripts/asus-trial-preflight.py} ${../scripts/test-asus-trial-preflight.py}
            python3 -I ${../scripts/test-asus-trial-preflight.py} ${../scripts/asus-trial-preflight.py}
            touch $out
          '';
      checks.asus-capacity-policy =
        assert lib.assertMsg (
          baseline.services.ollama.environmentVariables.OLLAMA_NUM_PARALLEL == "1"
        ) "ASUS capacity trial changed the default slot count";
        assert lib.assertMsg (
          trial.services.ollama.environmentVariables.OLLAMA_NUM_PARALLEL == "2"
        ) "ASUS capacity trial did not request two slots";
        assert lib.assertMsg (
          snapshot baseline == snapshot trial
          && (snapshot trial).powerLimit == 130
          && (snapshot trial).context == "32768"
        ) "ASUS capacity trial changed power, context, models or memory policy";
        assert lib.assertMsg (lib.all (
          a: a.assertion
        ) trial.assertions) "ASUS two-slot trial violates an existing assertion";
        assert lib.assertMsg (
          !invalid.success && !(lib.all (a: a.assertion) bypass.assertions)
        ) "ASUS slot policy accepted an invalid count or environment bypass";
        pkgs.writeText "asus-capacity-policy" (
          builtins.toJSON {
            baseline = snapshot baseline;
            trial = snapshot trial;
            baselineSlots = 1;
            trialSlots = 2;
            runtimeVerified = false;
          }
        );
    };
}
