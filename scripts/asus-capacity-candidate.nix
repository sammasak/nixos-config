# Build only, from an exact committed source revision. This never activates a configuration or wakes a host.
{
  revision,
  tree ? ../.,
  parallelRequests ? 2,
}:
assert builtins.match "[0-9a-f]{40}" revision != null;
assert builtins.elem parallelRequests [
  1
  2
];
let
  source = builtins.getFlake ("git+file://${toString tree}?rev=${revision}");
  candidate =
    (source.nixosConfigurations.asus-b460m.extendModules {
      modules = [ { homelab.ollama.parallelRequests = parallelRequests; } ];
    }).config;
in
assert candidate.homelab.ollama.gpuPowerLimit == 130;
assert candidate.services.ollama.environmentVariables.OLLAMA_CONTEXT_LENGTH == "32768";
candidate.system.build.toplevel
