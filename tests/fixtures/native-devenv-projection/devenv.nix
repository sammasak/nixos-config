{ pkgs, ... }:
{
  packages = [ pkgs.coreutils pkgs.gnumake pkgs.gcc ];
  env.PROJECT_CAPTURE_PROBE = builtins.getEnv "AGENT_RUNTIME_HOST_EVAL_PROBE";
  env.PROJECT_NATIVE_MARKER = "generated-devenv-environment";
  enterShell = ''
    printf '%s\n' "$PROJECT_NATIVE_MARKER" > "$DEVENV_ROOT/.devenv-enterShell-ran"
  '';
  scripts.check.exec = ''
    test "$PROJECT_NATIVE_MARKER" = generated-devenv-environment
    test -f "$DEVENV_ROOT/.devenv-enterShell-ran"
    make check
  '';
}
