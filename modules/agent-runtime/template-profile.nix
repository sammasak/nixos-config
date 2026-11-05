# The agent-runtime deploy-rs profile (#140): one host's template manifests,
# each referencing its closure, and an activation that refuses a host whose
# substrate cannot run them, so deploy-rs rolls the profile back instead of
# leaving unrunnable templates active.
{ lib, pkgs, agentRuntime, substrateSchema ? 1 }:
let
  activate = pkgs.writeShellApplication {
    name = "agent-runtime-templates-activate";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = ''
      profile=''${PROFILE:?deploy-rs sets PROFILE}
      substrate=/etc/agent-runtime/substrate.json
      [ -f "$substrate" ] || { echo "agent-runtime: no substrate on this host ($substrate); deploy the system profile first" >&2; exit 1; }
      jq -e '.kind == "agent-runtime-substrate" and .schemaVersion == ${toString substrateSchema}' "$substrate" >/dev/null || {
        echo "agent-runtime: these templates need substrate schemaVersion ${toString substrateSchema}, the host has $(jq -c .schemaVersion "$substrate")" >&2
        exit 1
      }
      n=0
      for t in "$profile"/templates/*.json; do
        jq -e '.kind == "agent-runtime-template" and .schemaVersion == 1' "$t" >/dev/null \
          || { echo "agent-runtime: $t is not a schemaVersion 1 template" >&2; exit 1; }
        name=$(jq -r .template.name "$t")
        jq -e --arg n "$name" '.eligibleTemplates | index($n)' /etc/agent-runtime/host.json >/dev/null \
          || echo "agent-runtime: $name is not eligible on this host and will not be admitted" >&2
        n=$((n + 1))
      done
      echo "agent-runtime: $n templates active from $(readlink -f "$profile")"
    '';
  };
in
pkgs.runCommand "agent-runtime-templates" { } ''
  mkdir -p $out/bin
  ln -s ${agentRuntime.manifestDir} $out/templates
  ln -s ${lib.getExe activate} $out/bin/agent-runtime-templates-activate
''
