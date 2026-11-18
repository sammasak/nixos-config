{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.source.rev = lib.mkForce "main";
}
