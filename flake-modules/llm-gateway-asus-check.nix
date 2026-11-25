# asus as acer's gateway provider: off, the deployed config is the base file's alone (the same store path); on, as
# acer has it, it is one tier-3 provider before msi; and each wrong fact (modules/homelab/llm-gateway-asus.nix) fails its own assertion.
{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.acer-swift;
  acer = host.config;
  inherit (host) pkgs;
  off =
    (host.extendModules {
      modules = [ { homelab.llmGateway.asus.enable = lib.mkForce false; } ];
    }).config;
  base = builtins.readFile ../modules/homelab/llm-gateway.toml;
  fragment = builtins.readFile ../modules/homelab/llm-gateway-asus.toml;
  address = acer.sam.fleet.hosts.asus-b460m.address;
  facts = {
    inherit base address;
    fragment = lib.replaceStrings [ "@asus@" ] [ address ] fragment;
    inherit (acer.sam.fleet.listeners.ollama-asus) port;
    enabledByDefault = host.options.homelab.llmGateway.asus.enable.default;
    unit = acer.systemd.services.llm-gateway;
  };
  failing =
    f:
    map (a: a.message) (
      lib.filter (a: !a.assertion) (import ../modules/homelab/llm-gateway-asus.nix { inherit lib; } f)
    );
  # the rendering before asus existed, byte for byte, and the same with the fragment appended: equal store paths
  rendered =
    lib.replaceStrings
      [ "@msi@" "@acer@" ]
      [ acer.sam.fleet.hosts.msi-ms7758.address acer.sam.fleet.hosts.acer-swift.address ]
      base;
  execStart = text: "${lib.getExe pkgs.llmGateway} ${pkgs.writeText "llm-gateway.toml" text}";
  edit =
    from: to:
    let
      text = lib.replaceStrings [ from ] [ to ] facts.fragment;
    in
    assert lib.assertMsg (
      text != facts.fragment
    ) "llm-gateway-asus-check: seed ${from} -> ${to} edits nothing";
    facts // { fragment = text; };
  unitWith =
    module:
    facts
    // {
      unit = (host.extendModules { modules = [ module ]; }).config.systemd.services.llm-gateway;
    };
  seeds = {
    enabled-by-default = facts // {
      enabledByDefault = true;
    };
    in-base-catalog = facts // {
      base = base + fragment;
    };
    two-slots = edit "max_concurrency = 1" "max_concurrency = 2";
    wrong-port = edit ":11434/" ":11435/";
    above-tier-3 = edit "tier = 3" "tier = 2";
    no-health-probe = edit "health_url" "# health_url";
    tool-capable-unverified = edit "Ollama's qwen3.5 parser" "unverified";
    start-requires-asus = unitWith {
      systemd.services.llm-gateway.requires = [ "ollama-asus-reachable.service" ];
    };
    start-probes-asus = unitWith {
      systemd.services.llm-gateway.serviceConfig.ExecStartPre =
        "${lib.getExe pkgs.curl} --fail http://${address}:11434/api/tags";
    };
  };
  # each seed fails the assertion whose message holds this
  expect = {
    enabled-by-default = "must default to false";
    in-base-catalog = "names an asus provider";
    two-slots = "max_concurrency = 1";
    wrong-port = "base_url and health_url";
    above-tier-3 = "tier 3, beside msi";
    no-health-probe = "base_url and health_url";
    tool-capable-unverified = "tool use is unverified";
    start-requires-asus = "must not require";
    start-probes-asus = "must not require";
  };
  onCatalog = builtins.fromTOML (facts.fragment + rendered);
  tier3 = map (m: m.provider) (lib.filter (m: m.tier == 3) onCatalog.models);
in
{
  perSystem =
    { system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.llm-gateway-asus =
        assert lib.assertMsg (
          failing facts == [ ]
        ) "acer's own asus facts fail: ${toString (failing facts)}";
        assert lib.assertMsg (
          off.systemd.services.llm-gateway.serviceConfig.ExecStart == execStart rendered
        ) "llm-gateway: with asus off the deployed config moved from llm-gateway.toml's rendering";
        assert lib.assertMsg
          (acer.systemd.services.llm-gateway.serviceConfig.ExecStart == execStart (facts.fragment + rendered))
          "llm-gateway: with asus on the deployed config is not llm-gateway-asus.toml then llm-gateway.toml";
        assert lib.assertMsg (lib.all (
          a: a.assertion
        ) off.assertions) "acer with asus off fails an assertion";
        assert lib.assertMsg
          (
            tier3 == [
              "asus"
              "msi"
              "msi"
            ]
            && lib.any (p: p.name == "asus" && p.max_concurrency == 1) onCatalog.providers
          )
          "llm-gateway: with asus on, tier 3 is not asus's one-slot provider then msi's models (${toString tier3})";
        assert lib.assertMsg (
          lib.attrNames seeds == lib.attrNames expect
        ) "llm-gateway-asus: a seed without its expected failure";
        assert lib.all (
          n:
          lib.assertMsg (lib.any (lib.hasInfix expect.${n}) (failing seeds.${n}))
            "llm-gateway-asus: seed ${n} does not fail on \"${expect.${n}}\" (${toString (failing seeds.${n})})"
        ) (lib.attrNames seeds);
        pkgs.writeText "llm-gateway-asus" (
          builtins.toJSON {
            seeds = lib.mapAttrs (_: failing) seeds;
            inherit tier3;
          }
        );
    };
}
