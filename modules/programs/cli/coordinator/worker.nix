# Worker side of the coordinator: a restricted-command authorized key per
# coordinator host (sam.coordinator.acceptKeys). NixOS module, auto-imported by
# the base role next to the other sam.* options.
{ config, lib, pkgs, ... }:
let
  keys = config.sam.coordinator.acceptKeys;
  shim = pkgs.writeShellApplication {
    name = "herdr-shim";
    runtimeInputs = [ pkgs.coreutils pkgs.bash pkgs.herdr ];
    text = builtins.readFile ./herdr-shim.sh;
  };
  restrict = key: "command=\"${shim}/bin/herdr-shim\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ${key}";
in
{
  config = lib.mkIf (keys != [ ]) {
    users.users.${config.sam.profile.username}.openssh.authorizedKeys.keys = map restrict keys;
  };
}
