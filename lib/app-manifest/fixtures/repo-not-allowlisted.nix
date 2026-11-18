{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.source.repo = lib.mkForce "mallory/notes";
}
