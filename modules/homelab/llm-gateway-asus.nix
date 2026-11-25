# asus's gateway provider (llm-gateway-asus.toml) as assertions over its facts: llm-gateway.nix asserts the real ones,
# flake-modules/llm-gateway-asus-check.nix feeds wrong ones that must each fail.
{ lib }:
{
  # llm-gateway.toml as read, and the fragment with @asus@ replaced
  base,
  fragment,
  address,
  # sam.fleet.listeners.ollama-asus.port and paddock-asus.port
  port,
  paddockPort,
  enabledByDefault,
  # systemd.services.llm-gateway
  unit,
}:
let
  where = "modules/homelab/llm-gateway-asus.toml";
  catalog = builtins.fromTOML fragment;
  baseCatalog = builtins.fromTOML base;
  providers = catalog.providers or [ ];
  byName = lib.listToAttrs (map (q: lib.nameValuePair (q.name or "") q) providers);
  p = byName.asus or { };
  paddock = byName.asus-paddock or { };
  models = catalog.models or [ ];
  url = path: "http://${address}:${toString port}${path}";
  paddockUrl = path: "http://${address}:${toString paddockPort}${path}";
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
      lib.length providers == 2
      && lib.all (q: q.kind or null == "ollama" && q.max_concurrency or null == 1) [
        p
        paddock
      ];
    message = "${where}: two providers, asus (Ollama) and asus-paddock, of kind ollama (no key, self-hosted) with max_concurrency = 1: each serves one request slot.";
  }
  {
    assertion = p.base_url or null == url "/v1" && p.health_url or null == url "/api/tags";
    message = "${where}: base_url and health_url must be ${url "/v1"} and ${url "/api/tags"} (sam.fleet.listeners.ollama-asus); without the probe every request tries asus while it is off.";
  }
  {
    assertion =
      paddock.base_url or null == paddockUrl "/v1" && paddock.health_url or null == paddockUrl "/healthz";
    message = "${where}: asus-paddock's base_url and health_url must be ${paddockUrl "/v1"} and ${paddockUrl "/healthz"} (sam.fleet.listeners.paddock-asus); without the probe every request tries Paddock while it is stopped.";
  }
  {
    assertion =
      models != [ ]
      && lib.all (
        m:
        lib.elem (m.provider or null) [
          "asus"
          "asus-paddock"
        ]
        && m.tier or null == 3
      ) models;
    message = "${where}: its models are asus's and tier 3, beside msi: the local floor, below every free cloud tier.";
  }
  {
    assertion =
      !lib.any (m: m.tool_capable or false && lib.hasInfix "unverified" (m.notes or "")) models;
    message = "${where}: a model is tool_capable while its notes say tool use is unverified (#494); verify a Pi tool loop on asus (the #620 canary through the gateway), then change the note with the flag.";
  }
  {
    assertion = !lib.any namesAsus links && !namesAsus hooks;
    message = "modules/homelab/llm-gateway.nix: llm-gateway.service must not require, wait for or probe asus at start; asus may be off, and the gateway must start and route without it.";
  }
]
