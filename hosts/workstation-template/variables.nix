# Host profile for workstation image generation.
{
  username = "lukas";
  hostname = "workstation-template";

  # Headless workstation image, no desktop role.
  roles = [ "base" ];

  # Keep SSH policy compatible with LAN access pattern.
  lanCidr = "192.168.10.0/24";
}
