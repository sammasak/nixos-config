{
  imports = [ ./valid-service.nix ];
  grants.notes.hostnames = [ "notes-public" ];
  apps.notes.ingress.notes-public.auth = "public";
}
