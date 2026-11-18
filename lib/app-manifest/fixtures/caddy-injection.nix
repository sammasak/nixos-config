# A path that would close the metrics handle and open a site of its own, were it written into the Caddyfile.
{
  imports = [ ./valid-service.nix ];
  apps.notes.runtime.service.metricsPath = "/metrics\n\t}\n}\n:8443 {\n\trespond pwned";
}
