hostName:
{ pkgs, lib, ... }:
let
  nativeOtelClaudeEnv = pkgs.writeShellApplication {
    name = "native-otel-claude-env";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      token_file=/run/secrets/native_otlp_auth
      if [ -r "$token_file" ]; then
        token=$(cat "$token_file")
        export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $token"
        export OTEL_RESOURCE_ATTRIBUTES="host.name=${lib.toLower hostName}"
      else
        unset OTEL_EXPORTER_OTLP_HEADERS
      fi
      exec "$@"
    '';
  };
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
    claude() {
      ${nativeOtelClaudeEnv}/bin/native-otel-claude-env ${pkgs.claude-code}/bin/claude "$@"
    }
  '';

  programs.fish.functions = {
    codex = ''
      ${nativeOtelCodexEnv}/bin/native-otel-codex-env ${pkgs.codex}/bin/codex $argv
    '';
    claude = ''
      ${nativeOtelClaudeEnv}/bin/native-otel-claude-env ${pkgs.claude-code}/bin/claude $argv
    '';
  };
}
