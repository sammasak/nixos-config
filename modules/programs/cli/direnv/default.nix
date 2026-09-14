{ ... }:
{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    config.global.hide_env_diff = true;
    # Explicit trusted roots, not a blanket /home/lukas prefix: a home-wide
    # whitelist would auto-run any .envrc from downloads or review checkouts.
    config.whitelist.prefix = [
      "/home/lukas/nixos-config"
      "/home/lukas/herman"
      "/home/lukas/doable-rs"
    ];
  };
}
