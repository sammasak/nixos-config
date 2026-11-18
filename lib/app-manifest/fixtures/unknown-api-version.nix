{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.apiVersion = lib.mkForce "v1alpha2";
}
