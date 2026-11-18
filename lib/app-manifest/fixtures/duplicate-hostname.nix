{
  imports = [ ./valid-service.nix ];
  grants.notes.hostnames = [ "herman-next" ];
  apps.notes.ingress.herman-next.auth = "authentik";
}
