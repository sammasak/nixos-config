# Worker side of the coordinator: a restricted-command authorized key per
# coordinator host (sam.coordinator.acceptKeys). NixOS module, auto-imported by
# the base role next to the other sam.* options.
{ config, lib, pkgs, ... }:
let
  keys = config.sam.coordinator.acceptKeys;
  shim = pkgs.writeShellApplication {
    name = "herdr-shim";
    runtimeInputs = [ pkgs.coreutils pkgs.gnused pkgs.bash pkgs.herdr ];
    text = builtins.readFile ./herdr-shim.sh;
  };
  restrict = key: "restrict,command=\"${shim}/bin/herdr-shim\" ${key}";
  blob = key: builtins.elemAt (lib.splitString " " key) 1;
  ownerBlobs = map blob (config.sam.userConfig.sshKeys or [ ]);
in
{
  config = lib.mkIf (keys != [ ]) {
    assertions = [{
      assertion = lib.all (k: !(builtins.elem (blob k) ownerBlobs)) keys;
      message = "sam.coordinator.acceptKeys must not contain the owner's own interactive keys: sshd would pick whichever authorized_keys line comes first and the restriction could be skipped.";
    }];
    users.users.${config.sam.profile.username}.openssh.authorizedKeys.keys = map restrict keys;
  };
}
