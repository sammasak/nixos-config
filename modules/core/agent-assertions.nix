# Cross-module checks on the agent stack (Herdr, native telemetry), evaluated on every host and fleet guest.
{ config, lib, ... }:
{
  config = {
    assertions = [
      {
        assertion =
          lib.length (lib.unique (map (m: m.label) config.sam.herdr.machines))
          == lib.length config.sam.herdr.machines;
        message = "sam.herdr.machines labels must be unique (herdr --machine addresses a machine by its label).";
      }
      {
        # the unattended Coordinator stays on dontAsk: it must never share a settings.json that skips the bypass dialog;
        # elsewhere the module's coordinatorHost gate would drop the wake-up and report timers without a word
        assertion =
          config.sam.herdr.coordinatorWakeup.enable
          -> (config.sam.herdr.machines != [ ] && !config.sam.herdr.worker.enable);
        message = "sam.herdr.coordinatorWakeup (the wake-up and the coordinator-report timers) runs only on the coordinator host: one that declares sam.herdr.machines and is not a sam.herdr.worker (the Coordinator must not inherit worker permissions).";
      }
      {
        assertion =
          !config.sam.profile.devTools
          || (
            (config.home-manager.users.${config.sam.profile.username}.systemd.user.services.herdr.Unit.X-SwitchMethod
              or null
            ) == "keep-old"
          );
        message = "a devTools host's Herdr user unit must carry X-SwitchMethod = keep-old, or a switch kills every agent session.";
      }
      {
        assertion =
          !config.sam.profile.devTools
          || (
            (config.home-manager.users.${config.sam.profile.username}.systemd.user.services.herdr.Service.OOMPolicy
              or null
            ) == "continue"
          );
        message = "a devTools host's Herdr user unit must carry OOMPolicy = continue, or one kernel OOM kill stops every agent session.";
      }
      (
        let
          inherit (config.sam.profile) devTools nativeOtel;
          claudeOtel = config.sam.claude.telemetry.enable;
          codexOtel = devTools && (nativeOtel || claudeOtel);
          hm = config.home-manager.users.${config.sam.profile.username} or { };
          env = hm.programs.claude-code.settings.env or { };
          # The rollback (docs/native-otel-canary.md) is nativeOtel = false with sam.claude.telemetry at its default:
          # every surface off. Checked both ways: a surface whose option path moves fails where it is on, not passes as gone.
          surfaces = {
            "the native-otel-relay unit" = {
              present = config.systemd.services ? native-otel-relay;
              want = nativeOtel;
            };
            "the sops secret native_otlp_auth" = {
              present = (config.sops.secrets or { }) ? native_otlp_auth;
              want = nativeOtel;
            };
            "Claude's telemetry env (OTEL_*, HARNESS_*, CLAUDE_CODE_ENABLE_TELEMETRY, CLAUDE_CODE_SUBPROCESS_ENV_SCRUB)" =
              {
                present = lib.any (
                  k:
                  lib.hasPrefix "OTEL_" k
                  || lib.hasPrefix "HARNESS_" k
                  || builtins.elem k [
                    "CLAUDE_CODE_ENABLE_TELEMETRY"
                    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"
                  ]
                ) (builtins.attrNames env);
                want = devTools && claudeOtel;
              };
            "Claude's DISABLE_TELEMETRY = \"1\"" = {
              present = (env.DISABLE_TELEMETRY or null) == "1";
              want = devTools && !claudeOtel;
            };
            # Not Codex's [otel] stanza: config.toml's text forces chromium and playwright-mcp.
            # `? text`, not the text: only native-otel.nix's script carries one, and reading it forces pkgs.codex.
            "the OTEL_ codex wrapper" = {
              present = lib.any (p: (p.pname or p.name or "") == "codex" && p ? text) (hm.home.packages or [ ]);
              want = codexOtel;
            };
          };
          wrong = lib.attrNames (lib.filterAttrs (_: s: s.present != s.want) surfaces);
        in
        {
          assertion = wrong == [ ];
          message = "sam.profile.nativeOtel = ${lib.boolToString nativeOtel}, sam.claude.telemetry.enable = ${lib.boolToString claudeOtel}: ${
            lib.concatMapStringsSep ", " (
              n: "${n} is ${if surfaces.${n}.present then "present" else "missing"}"
            ) wrong
          }.";
        }
      )
    ];
  };
}
