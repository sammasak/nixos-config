# A host's memory budget, stated once (nixos-config#354): its RAM, the hard caps of the units that can grow without
# bound, and the floors of the services that must keep answering, applied to the units here. Evaluation fails when
# every MemoryMax on the host's services and slices, set here or by any module, plus the floors exceeds the RAM.
# The kernel, page tables and the zram store are in no cgroup and not in the sum: the budget says what is left for them.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.sam.memory;
  size = types.strMatching "[0-9]+[KMG]?";
  bytes =
    v:
    let
      m = builtins.match "([0-9]+)([KMG]?)" v;
    in
    lib.toInt (builtins.elemAt m 0)
    * {
      "" = 1;
      K = 1024;
      M = 1048576;
      G = 1073741824;
    }
    .${builtins.elemAt m 1};
  # "user.slice" -> systemd.slices.user.sliceConfig, "nix-daemon.service" -> systemd.services.nix-daemon.serviceConfig
  unit =
    name: settings:
    let
      m = builtins.match "(.+)[.](service|slice)" name;
      base = builtins.elemAt m 0;
    in
    if m == null then
      throw "sam.memory: ${name} is neither a .service nor a .slice"
    else if builtins.elemAt m 1 == "service" then
      { services.${base}.serviceConfig = settings; }
    else
      { slices.${base}.sliceConfig = settings; };
  capped = lib.mapAttrs (
    _: c:
    {
      MemoryMax = c.max;
    }
    // lib.optionalAttrs (c.high != null) { MemoryHigh = c.high; }
    // lib.optionalAttrs (c.swapMax != null) { MemorySwapMax = c.swapMax; }
  ) cfg.caps;
  # every cap on the host, so one a module adds later is counted too
  allCaps = lib.filterAttrs (_: v: v != null) (
    lib.mapAttrs' (
      n: u: lib.nameValuePair "${n}.service" (u.serviceConfig.MemoryMax or null)
    ) config.systemd.services
    // lib.mapAttrs' (
      n: u: lib.nameValuePair "${n}.slice" (u.sliceConfig.MemoryMax or null)
    ) config.systemd.slices
  );
  unsized = lib.attrNames (
    lib.filterAttrs (_: v: builtins.match "[0-9]+[KMG]?" (toString v) == null) allCaps
  );
  caps = lib.foldl' (s: v: s + bytes (toString v)) 0 (
    lib.attrValues (lib.filterAttrs (n: _: !lib.elem n unsized) allCaps)
  );
  floors = lib.foldl' (s: f: s + bytes f) 0 (lib.attrValues cfg.floors);
  mib = b: "${toString (b / 1048576)}M";
in
{
  options.sam.memory = {
    ram = mkOption {
      type = types.nullOr size;
      default = null;
      description = "The RAM the budget divides: MemTotal, rounded down.";
    };
    caps = mkOption {
      default = { };
      description = "Hard caps by unit name (*.service or *.slice): MemoryMax, and optionally MemoryHigh and MemorySwapMax.";
      type = types.attrsOf (
        types.submodule {
          options = {
            max = mkOption {
              type = size;
              description = "The unit's MemoryMax, the hard cap counted in the budget's sum.";
            };
            high = mkOption {
              type = types.nullOr size;
              default = null;
              description = "The unit's MemoryHigh, where the kernel starts reclaiming and throttling it; null sets none.";
            };
            swapMax = mkOption {
              type = types.nullOr size;
              default = null;
              description = "The unit's MemorySwapMax; null sets none (the systemd default, no swap limit).";
            };
          };
        }
      );
    };
    floors = mkOption {
      type = types.attrsOf size;
      default = { };
      description = "MemoryMin by service name; system.slice gets their sum, as a child's floor holds only under its parent's.";
    };
  };

  config = lib.mkIf (cfg.ram != null) {
    systemd = lib.mkMerge (
      lib.mapAttrsToList unit capped
      ++ lib.mapAttrsToList (n: f: unit n { MemoryMin = f; }) cfg.floors
      ++ lib.optional (cfg.floors != { }) { slices.system.sliceConfig.MemoryMin = mib floors; }
    );

    assertions = [
      {
        assertion = caps + floors <= bytes cfg.ram;
        message = "sam.memory on ${config.networking.hostName}: the caps (${mib caps}: ${
          lib.concatStringsSep ", " (lib.mapAttrsToList (n: v: "${n} ${toString v}") allCaps)
        }) plus the floors (${mib floors}) exceed the RAM (${cfg.ram}); with every capped unit at its MemoryMax the floors could not be kept. Lower a cap or a floor.";
      }
      {
        assertion = unsized == [ ];
        message = "sam.memory on ${config.networking.hostName}: ${toString unsized} has a MemoryMax the budget cannot size (want bytes with K, M or G).";
      }
      {
        assertion = lib.all (n: lib.hasSuffix ".service" n) (lib.attrNames cfg.floors);
        message = "sam.memory on ${config.networking.hostName}: floors are for services in system.slice, whose MemoryMin is their sum; ${toString (lib.attrNames cfg.floors)}.";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (n: c: [
        {
          assertion = c.high == null || bytes c.high < bytes c.max;
          message = "sam.memory on ${config.networking.hostName}: ${n} MemoryHigh ${toString c.high} must be below its MemoryMax ${c.max}, so it is throttled before it is killed.";
        }
        {
          # zram is charged to no cgroup: a swap cap above a quarter of the cap hides that much more from the budget
          assertion = c.swapMax == null || bytes c.swapMax * 4 <= bytes c.max;
          message = "sam.memory on ${config.networking.hostName}: ${n} MemorySwapMax ${toString c.swapMax} is above a quarter of its MemoryMax ${c.max}.";
        }
      ]) cfg.caps
    );
  };
}
