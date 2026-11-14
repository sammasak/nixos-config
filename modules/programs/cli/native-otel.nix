{
  pkgs,
  lib,
  osConfig,
  ...
}:
let
  inherit (osConfig.sam.claude.telemetry) resourceAttributes;
in
{
  # The codex on PATH, so non-interactive callers export too; without both the gateway drops its metrics.
  # hiPrio: wins bin/codex over the codex module's pkgs.codex, whose other outputs stay.
  home.packages = lib.optional (osConfig.sam.profile.devTools or false) (
    lib.hiPrio (
      pkgs.writeShellApplication {
        name = "codex";
        text = ''
          export OTEL_RESOURCE_ATTRIBUTES=${
            lib.escapeShellArg (
              lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") resourceAttributes)
            )
          }
          export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative
          exec ${pkgs.codex}/bin/codex "$@"
        '';
      }
    )
  );
}
