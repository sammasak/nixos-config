{ config, lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # The #165 pilot template through the E2E path; a package like the other agent-runtime VM tests,
      # run explicitly: `nix build .#packages.x86_64-linux.agent-runtime-pilot-test` (acer, heavy lock).
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-pilot-test = import ../tests/agent-runtime-pilot.nix {
          inherit pkgs lib;
          inherit (inputs) factum skills;
        };
      };

      # What acer-swift renders for the pilot, at evaluation (part of `nixos:qa` through flake check):
      # the one-instance policy, the credential-free, network-off template and its budgets, the tools
      # on the host, and no other host enabled. The output is the rendered policy and manifest.
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-acer-pilot =
        let
          hosts = config.flake.nixosConfigurations;
          acer = hosts.acer-swift.config;
          rt = acer.sam.agentRuntime;
          tpl = rt.manifestData.rust-pilot;
          coder = rt.manifestData.claude-coder;
          # the real runner store path, read to prove no reintroduced ANTHROPIC_* auth path (#169)
          coderRun = lib.findFirst (p: lib.getName p == "claude-coder-run")
            (throw "agent-runtime-acer-pilot: claude-coder-run package missing")
            acer.sam.agentRuntime.templates.claude-coder.packages;
          runnerText = builtins.readFile "${coderRun}/bin/claude-coder-run";
          names = map (p: p.name or "") acer.environment.systemPackages;
          others = lib.filter (n: n != "acer-swift" && hosts.${n}.config.sam.agentRuntime.host.enable) (lib.attrNames hosts);
          othersCoder = lib.filter (n: n != "acer-swift" && lib.elem "claude-coder" hosts.${n}.config.sam.agentRuntime.host.eligibleTemplates) (lib.attrNames hosts);
          expect = cond: msg: lib.assertMsg cond "agent-runtime-acer-pilot: ${msg}";
        in
        assert expect (rt.host.enable && rt.host.eligibleTemplates == [ "rust-pilot" "claude-coder" ]) "acer-swift admits exactly rust-pilot then claude-coder";
        assert expect (rt.host.maxConcurrentInstances == 1) "one instance at a time";
        assert expect (rt.host.reserve == { memoryMiB = 4096; diskMiB = 51200; }) "the reserve keeps 4 GiB and 50 GiB free";
        assert expect (rt.host.allowedMountRoots == [ ]) "no host mounts";
        assert expect (tpl.policies.network == { egress = "none"; allow = [ ]; }) "no network";
        assert expect (tpl.policies.capabilities == [ ] && tpl.policies.privateSources == [ ]) "no credential";
        assert expect (tpl.policies.resources == { cpus = 2; memoryMiB = 3072; tasksMax = 512; timeoutMinutes = 20; }) "the measured budgets";
        assert expect (tpl.filesystem.mounts == [ ]) "no extra mounts";
        assert expect (tpl.sources.factum.writable && tpl.sources.factum.locked.rev == inputs.factum.rev) "factum at the flake's pinned rev, a private writable copy";
        assert expect (lib.all (n: lib.elem n names) [ "agent-runtime-instance" "agent-runtime-preflight" "agent-runtime-pane" "agent-runtime-herdr" ]) "the lifecycle, preflight, pane and Herdr adapter on the host";
        assert expect (others == [ ]) "no other host enables the runtime (got ${toString others})";
        # The #169 coder template admitted beside rust-pilot: egress is exactly the Claude API host,
        # no credential, no ANTHROPIC_* auth path in the runner, and admitted on acer-swift only.
        assert expect (coder.policies.network == { egress = "allowlist"; allow = [ "api.anthropic.com" ]; }) "claude-coder egress is exactly api.anthropic.com (no wildcard, no extra host)";
        assert expect (coder.policies.capabilities == [ ]) "claude-coder grants no capability (no GitHub token)";
        assert expect (!(lib.hasInfix "ANTHROPIC_API_KEY=" runnerText) && !(lib.hasInfix "ANTHROPIC_AUTH_TOKEN=" runnerText)) "claude-coder runner assigns no ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN";
        assert expect (lib.hasInfix "unset ANTHROPIC_API_KEY" runnerText) "claude-coder runner unsets the ANTHROPIC_* auth paths";
        assert expect (othersCoder == [ ]) "no host other than acer-swift admits claude-coder (got ${toString othersCoder})";
        pkgs.runCommand "agent-runtime-acer-pilot" { nativeBuildInputs = [ pkgs.jq ]; } ''
          mkdir $out
          jq -S . ${rt.hostPolicy} > $out/host.json
          jq -S . ${rt.manifestDir}/rust-pilot.json > $out/rust-pilot.json
          jq -S . ${rt.manifestDir}/claude-coder.json > $out/claude-coder.json
        '';
      };
    };
}
