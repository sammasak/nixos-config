{
  imports = [ ./valid-service.nix ];
  apps.notes.systemd.serviceConfig.User = "root";
}
