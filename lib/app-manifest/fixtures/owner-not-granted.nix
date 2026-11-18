{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.owner = lib.mkForce "mallory";
}
