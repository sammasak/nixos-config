{
  imports = [ ./valid-service.nix ];
  grants.notes.secrets = [ "notes/api_key" ];
  apps.notes.runtime.service.secrets."notes/api_key" = { };
}
