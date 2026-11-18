# acer's keyless llm-gateway listens on 127.0.0.1:11435; a manifest has no port to aim the edge at it.
{
  imports = [ ./valid-service.nix ];
  apps.notes.runtime.service.port = 11435;
}
