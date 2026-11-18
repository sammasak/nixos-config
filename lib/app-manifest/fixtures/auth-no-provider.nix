# valid-service against an edge that defines no authentik snippet: scripts/test-app-manifest.py empties forwardAuth
# for this case alone.
{
  imports = [ ./valid-service.nix ];
}
