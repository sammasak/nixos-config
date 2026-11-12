# lenovo and the environment hosts serve their own /nix/store to the fleet over the LAN (harmonia), so what one
# machine built the others download. Each signs with a key generated on the host that never leaves it; its public half is below.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkMerge;
  inherit (import ../../lib/firewall.nix lib) mkDualBackendFirewall;
  cfg = config.sam.storeCache;
  host = config.networking.hostName;
  port = 5000;
  dir = "/var/lib/store-cache";

  # publicKey: `cat ${dir}/public-key` on the host after its first deploy with `serve`; null until then
  caches = {
    lenovo-21CB001PMX = { address = "192.168.10.154"; publicKey = "lenovo-21CB001PMX-store-1:Ifjt/zTBnDw6GFhAw6w6L0JGWHblrWr4V7L/BfphwPU="; };
    acer-swift = { address = "192.168.10.110"; publicKey = "acer-swift-store-1:iDCzz1UQib6s9pZ818Evy6d8naQ+4jaI6YYZmlGsz5A="; };
    msi-ms7758 = { address = "192.168.10.235"; publicKey = "msi-ms7758-store-1:xIr/Ee7u3rhCm4bhycovNFbfA2UAB6OITroVVWmv7wQ="; };
  };
  peers = lib.filterAttrs (name: c: name != host && c.publicKey != null) caches;

  rules = mkDualBackendFirewall {
    nftComment = "The store cache answers the LAN only.";
    ports = [ port ];
    sources = [ config.sam.profile.lanCidr ];
    interfaces = [ ];
    backend = config.networking.firewall.backend;
  };
in
{
  options.sam.storeCache = {
    serve = mkEnableOption "serving this host's Nix store to the LAN as a signed binary cache";
    use = mkEnableOption "substituting from the fleet's store caches";
  };

  config = mkMerge [
    (mkIf cfg.serve {
      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ "${dir}/secret-key" ];
        # ahead of cache.nixos.org (40): a path a neighbour holds comes over the LAN
        settings = { bind = "[::]:${toString port}"; priority = 30; };
      };
      systemd.services.store-cache-key = {
        description = "Signing key of this host's store cache";
        wantedBy = [ "multi-user.target" ];
        requiredBy = [ "harmonia.service" ];
        before = [ "harmonia.service" ];
        unitConfig.ConditionPathExists = "!${dir}/secret-key";
        serviceConfig = { Type = "oneshot"; StateDirectory = "store-cache"; UMask = "0077"; };
        path = [ config.nix.package pkgs.coreutils ];
        script = ''
          nix --extra-experimental-features nix-command key generate-secret --key-name ${host}-store-1 > ${dir}/secret-key.new
          nix --extra-experimental-features nix-command key convert-secret-to-public < ${dir}/secret-key.new > ${dir}/public-key
          chmod 0755 ${dir} && chmod 0644 ${dir}/public-key
          mv ${dir}/secret-key.new ${dir}/secret-key
        '';
      };
      networking.firewall = { inherit (rules) extraInputRules extraCommands; };
    })
    (mkIf (cfg.use && peers != { }) {
      nix.settings = {
        substituters = lib.mapAttrsToList (_: c: "http://${c.address}:${toString port}") peers;
        trusted-public-keys = lib.mapAttrsToList (_: c: c.publicKey) peers;
        # msi sleeps at night: give up on an absent cache quickly and build
        connect-timeout = 3;
        fallback = true;
      };
    })
  ];
}
