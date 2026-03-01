# Host profile for OpenFang agent image generation.
{
  username = "lukas";
  hostname = "openfang-agent";

  # Headless agent runtime, base role only.
  roles = [ "base" ];

  # Keep SSH policy compatible with LAN access pattern.
  lanCidr = "192.168.10.0/24";
}
