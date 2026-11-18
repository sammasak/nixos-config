{
  imports = [ ./valid-service.nix ];
  apps.notes.runtime.service.metricsPath = "metrics";
}
