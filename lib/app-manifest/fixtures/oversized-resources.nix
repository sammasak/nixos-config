{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.runtime.service.resources.memoryMiB = lib.mkForce 65536;
}
