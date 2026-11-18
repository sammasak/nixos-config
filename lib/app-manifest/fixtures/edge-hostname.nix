{
  imports = [ ./valid-service.nix ];
  grants.notes.hostnames = [ "auth" ];
  apps.notes.ingress.auth.auth = "public";
}
