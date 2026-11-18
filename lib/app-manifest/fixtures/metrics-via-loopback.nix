# An authority where a path goes: the metrics handle's rewrite would name another listener than the app's socket.
{ lib, ... }:
{
  imports = [ ./valid-service.nix ];
  apps.notes.runtime.service.metricsPath = lib.mkForce "//127.0.0.1/metrics";
}
