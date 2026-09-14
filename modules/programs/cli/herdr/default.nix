# Persistent terminal workspace for AI coding agents, on every host: the worker
# runs the herdr server that the desktop drives over `herdr --remote acer-swift`.
{ pkgs, osConfig, ... }:
let
  # delivery = "system" needs an OS notification daemon; the headless worker has
  # none, so it falls back to herdr's own in-app toasts (rendered in the client).
  toastDelivery = if (osConfig.sam.desktop.enable or false) then "system" else "herdr";
in
{
  home.packages = [ pkgs.herdr ];

  # A read-only symlink means `herdr config reset-keys` / in-app edits cannot
  # persist; the config is owned here and reapplied on rebuild.
  xdg.configFile."herdr/config.toml".text = ''
    # Owned here because the config symlink is read-only: herdr cannot persist the
    # onboarding dismissal itself (it fails with "os error 30" on every start).
    onboarding = false

    [terminal]
    default_shell = "fish"

    [theme]
    name = "terminal"

    [ui]
    # Not the default dots: shapes stay readable regardless of theme colors.
    status_indicators = "symbols"

    [ui.toast]
    delivery = "${toastDelivery}"
  '';
}
