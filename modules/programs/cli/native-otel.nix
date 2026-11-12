hostName:
{
  pkgs,
  lib,
  osConfig,
  ...
}:
let
  nativeOtelCodexEnv = pkgs.writeShellApplication {
    name = "native-otel-codex-env";
    text = ''
      export OTEL_RESOURCE_ATTRIBUTES="host.name=${lib.toLower hostName}"
      export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative
      exec "$@"
    '';
  };
in
{
  programs.bash.initExtra = lib.mkAfter ''
    codex() {
      ${nativeOtelCodexEnv}/bin/native-otel-codex-env ${pkgs.codex}/bin/codex "$@"
    }
  '';

  programs.fish.functions =
    if osConfig.sam.profile.devTools or false then
      {
        codex = lib.mkBefore ''
          set -lx OTEL_RESOURCE_ATTRIBUTES "host.name=${lib.toLower hostName}"
          set -lx OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE cumulative
        '';
      }
    else
      {
        codex = ''
          ${nativeOtelCodexEnv}/bin/native-otel-codex-env ${pkgs.codex}/bin/codex $argv
        '';
      };
}
