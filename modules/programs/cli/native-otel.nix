hostName:
{ pkgs, lib, ... }:
let
  nativeOtelEnv = pkgs.writeShellApplication {
    name = "native-otel-env";
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
in
{
  programs.bash.initExtra = lib.mkAfter ''
    codex() {
      ${nativeOtelEnv}/bin/native-otel-env ${pkgs.codex}/bin/codex "$@"
    }
    claude() {
      ${nativeOtelEnv}/bin/native-otel-env ${pkgs.claude-code}/bin/claude "$@"
    }
  '';

  programs.fish.functions = {
    codex = ''
      ${nativeOtelEnv}/bin/native-otel-env ${pkgs.codex}/bin/codex $argv
    '';
    claude = ''
      ${nativeOtelEnv}/bin/native-otel-env ${pkgs.claude-code}/bin/claude $argv
    '';
  };
}
