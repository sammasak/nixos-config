# The real Devenv project definition evaluated by the test derivation. The
# script itself runs only in the isolated guest, never during host preparation.
{ pkgs, ... }:
{
  packages = [ pkgs.gnumake pkgs.gcc pkgs.coreutils ];
  scripts.check.exec = ''
    test "$DEVENV_IMPORT_MARKER" = "tooling-import-loaded"
    echo "devenv-script:$DEVENV_IMPORT_MARKER" > "$DEVENV_ROOT/.devenv-script-ran"
    make check
  '';
}
