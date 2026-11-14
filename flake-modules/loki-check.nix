# homelab.loki on a seeded msi, as no host enables it yet. Building the check realises only ExecStart's context,
# the loki package and upstream's validate-loki-conf (loki -verify-config on the rendered file), never a toplevel;
# evaluating it requires the seed to pass the module's assertions and each wrong configuration to fail its own.
{ config, lib, ... }:
let
  msi = config.flake.nixosConfigurations.msi-ms7758;
  seed =
    module:
    (msi.extendModules {
      modules = [
        ../modules/homelab/loki.nix
        {
          homelab.loki = {
            enable = true;
            ntfyUrl = "http://ntfy.example/loki";
          };
        }
        module
      ];
    });
  failing = s: map (a: a.message) (builtins.filter (a: !a.assertion) s.config.assertions);
  expectFailure =
    name: c: prefix:
    lib.assertMsg (lib.any (lib.hasPrefix prefix) (failing c)) "loki-check: ${name} passes the assertion ${prefix}";
  lan = seed {
    homelab.loki = {
      listenAddress = "192.0.2.10";
      allowedSources = [ "192.0.2.0/24" ];
    };
  };
  # the loopback default with sources and a retention under 24h
  local = seed {
    homelab.loki = {
      allowedSources = [ "192.0.2.0/24" ];
      retention = "12h";
    };
  };
  anyAddress = seed {
    homelab.loki.listenAddress = "0.0.0.0";
    networking.firewall.enable = lib.mkForce false;
  };
in
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        loki-config-msi-ms7758 = pkgs.writeText "loki-config-msi-ms7758" (
          assert lib.assertMsg (
            failing lan == [ ]
          ) "loki-check: the seeded msi fails ${toString (failing lan)}";
          assert expectFailure "loopback with sources" local "homelab.loki.allowedSources";
          assert expectFailure "retention 12h" local "homelab.loki.retention 12h";
          assert expectFailure "0.0.0.0 without the firewall" anyAddress "homelab.loki.listenAddress 0.0.0.0";
          # upstream validates only without configFile and extraFlags; otherwise this check would pass unvalidated
          assert lib.assertMsg
            (lib.hasInfix "-validate-loki-conf" lan.config.systemd.services.loki.serviceConfig.ExecStart)
            "loki-check: ExecStart skips upstream's loki -verify-config";
          lan.config.systemd.services.loki.serviceConfig.ExecStart
        );
      };
    };
}
