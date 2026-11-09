{ pkgs, ... }:
{
  packages = [ pkgs.coreutils pkgs.gnumake pkgs.gcc pkgs.rustc ];
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
