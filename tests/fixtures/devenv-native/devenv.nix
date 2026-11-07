# The devenv shell definition. `packages` is the selected toolchain; `enterShell`
# and `scripts.*` are hooks. Hooks only ever execute inside the guest instance,
# never on the trusted host during preparation.
{ pkgs, ... }:
{
  packages = [ pkgs.gnumake pkgs.gcc pkgs.coreutils ];
  enterShell = ''
    echo "entered devenv shell" > "$DEVENV_ROOT/.devenv-shell-hook-ran"
  '';
  scripts.check.exec = "make check";
}
