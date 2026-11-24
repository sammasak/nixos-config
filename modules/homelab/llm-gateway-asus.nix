# asus's gateway provider (llm-gateway-asus.toml) as assertions over its facts: llm-gateway.nix asserts the real ones,
# flake-modules/llm-gateway-asus-check.nix feeds wrong ones that must each fail.
{ lib }:
{
  # llm-gateway.toml as read, and the fragment with @asus@ replaced
  base,
  fragment,
  address,
  # sam.fleet.listeners.ollama-asus.port
  port,
  enabledByDefault,
  # systemd.services.llm-gateway
  unit,
}:
let
  where = "modules/homelab/llm-gateway-asus.toml";
  catalog = builtins.fromTOML fragment;
  baseCatalog = builtins.fromTOML base;
  providers = catalog.providers or [ ];
  p = if providers == [ ] then { } else lib.head providers;
  models = catalog.models or [ ];
  url = path: "http://${address}:${toString port}${path}";
  # what could pull in, order or gate the gateway's start on asus
  links = lib.concatMap (f: unit.${f} or [ ]) [
    "requires"
    "requisite"
    "bindsTo"
    "wants"
    "after"
    "upholds"
    "partOf"
  ];
  hooks = builtins.toJSON {
    inherit (unit) serviceConfig unitConfig environment;
    preStart = unit.preStart or "";
    script = unit.script or "";
  };
  namesAsus = s: lib.hasInfix "asus" s || lib.hasInfix address s;
in
[
  {
    assertion = !enabledByDefault;
    message = "${where}: homelab.llmGateway.asus.enable must default to false; a host opts in.";
  }
  {
    assertion =
      !lib.any (q: q.name or null == "asus") (baseCatalog.providers or [ ])
      && !lib.any (m: m.provider or null == "asus") (baseCatalog.models or [ ]);
    message = "modules/homelab/llm-gateway.toml: names an asus provider or model, so asus is routed without homelab.llmGateway.asus.enable; keep it in ${where}.";
  }
  {
    assertion =
      lib.length providers == 1
      && p.name or null == "asus"
      && p.kind or null == "ollama"
      && p.max_concurrency or null == 1;
    message = "${where}: one provider, asus, of kind ollama with max_concurrency = 1: asus serves one request slot.";
  }
  {
    assertion = p.base_url or null == url "/v1" && p.health_url or null == url "/api/tags";
    message = "${where}: base_url and health_url must be ${url "/v1"} and ${url "/api/tags"} (sam.fleet.listeners.ollama-asus); without the probe every request tries asus while it is off.";
  }
  {
    assertion =
      models != [ ] && lib.all (m: m.provider or null == "asus" && m.tier or null == 3) models;
    message = "${where}: its models are asus's and tier 3, beside msi: the local floor, below every free cloud tier.";
  }
  {
    assertion =
      !lib.any (m: m.tool_capable or false && lib.hasInfix "unverified" (m.notes or "")) models;
    message = "${where}: a model is tool_capable while its notes say tool use is unverified (#494); verify a Pi tool loop on asus with the replay, then change the note with the flag.";
  }
  {
    assertion = !lib.any namesAsus links && !namesAsus hooks;
    message = "modules/homelab/llm-gateway.nix: llm-gateway.service must not require, wait for or probe asus at start; asus may be off, and the gateway must start and route without it.";
  }
]
