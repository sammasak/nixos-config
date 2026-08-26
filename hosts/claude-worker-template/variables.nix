# Host profile for Claude Worker agent image generation.
{
  username = "lukas";
  hostname = "claude-worker";

  # Headless agent runtime, base role only.
  roles = [ "base" ];

  # Keep SSH policy compatible with LAN access pattern.
  lanCidr = "192.168.10.0/24";
}
