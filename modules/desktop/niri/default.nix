# Niri desktop (system-wide), coexisting with Hyprland: both session files
# land in the SDDM greeter and the compositor is picked at sign-in.
{ pkgs, ... }:
{
  programs.niri.enable = true;

  # Bare, not mkDefault: daily-driver default; explicit so it never ties with
  # another module's mkDefault (hyprland's did exactly that before).
  services.displayManager.defaultSession = "niri";

  # X11 clients under niri need an external Xwayland shim; the nixpkgs niri
  # module does not install one.
  environment.systemPackages = [ pkgs.xwayland-satellite ];
}
