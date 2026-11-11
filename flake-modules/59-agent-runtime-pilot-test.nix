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

      # What Acer and MSI render for the pilot at evaluation (part of `nixos:qa` through flake check):
      # host policies, the network-off pilot and the single-egress coder template, required host/Herdr tools, and preserved host policy.
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-msi-pilot =
        let
          hosts = config.flake.nixosConfigurations;
          msi = hosts.msi-ms7758.config;
          lenovo = hosts.lenovo.config;
          rt = msi.sam.agentRuntime;
          tpl = rt.manifestData.rust-pilot;
          username = msi.sam.profile.username;
          hm = msi.home-manager.users.${username};
          flags = msi.homelab.k3s.extraFlags;
          names = map (p: p.name or "") msi.environment.systemPackages;
          shutdownTimer = msi.systemd.timers.msi-scheduled-shutdown.timerConfig;
          wakeService = lenovo.systemd.services.msi-wake.serviceConfig.ExecStart;
          wakeTimer = lenovo.systemd.timers.msi-wake.timerConfig;
          shutdownScript = msi.systemd.services.msi-scheduled-shutdown.serviceConfig.ExecStart;
          expect = cond: msg: lib.assertMsg cond "agent-runtime-msi-pilot: ${msg}";
        in
        assert expect (rt.host.enable && rt.host.eligibleTemplates == [ "rust-pilot" "claude-coder" ]) "MSI admits exactly rust-pilot then claude-coder";
        assert expect (rt.manifestData.claude-coder.policies.network == { egress = "allowlist"; allow = [ "api.anthropic.com" ]; }) "MSI's claude-coder egress is exactly api.anthropic.com";
        assert expect (rt.manifestData.claude-coder.policies.capabilities == [ ]) "MSI's claude-coder grants no capability";
        assert expect (msi.sops.secrets.claude_oauth_token.mode == "0400" && msi.sops.secrets.claude_oauth_token.owner == username) "the subscription token is owner-only on MSI";
        assert expect (rt.host.maxConcurrentInstances == 2) "bounded two-instance admission";
        assert expect (rt.host.reserve == { cpus = 2; memoryMiB = 8192; diskMiB = 51200; }) "retain 2 logical CPUs, 8 GiB RAM and 50 GiB disk for host workloads";
        assert expect (tpl.policies.network == { egress = "none"; allow = [ ]; }) "no network egress";
        assert expect (tpl.policies.capabilities == [ ] && tpl.policies.privateSources == [ ]) "no credentials or privileged capabilities";
        assert expect (tpl.policies.resources.memoryMiB == 3072 && tpl.policies.resources.cpus == 2) "reuse the pilot template resource cap (MSI headroom still needs live validation)";
        assert expect msi.homelab.msiPowerSchedule.selfShutdown.enable "preserve the scheduled shutdown";
        assert expect (shutdownTimer.OnCalendar == "Mon-Fri 21:00" && shutdownTimer.Persistent == false) "preserve MSI's weekday 21:00 shutdown without catch-up";
        assert expect lenovo.homelab.msiPowerSchedule.waker.enable "preserve Lenovo's MSI wake configuration";
        assert expect (lib.hasInfix "/bin/wakeonlan d4:3d:7e:4a:f9:3d" wakeService) "preserve the MSI Wake-on-LAN target";
        assert expect (wakeTimer.OnCalendar == "Mon-Fri 09:00" && wakeTimer.Persistent == false) "preserve weekday 09:00 wake without catch-up";
        assert expect (msi.services.k3s.enable && msi.homelab.k3s.cni == "cilium") "preserve the active Cilium k3s worker";
        assert expect (lib.elem "--node-label=node-pool=workers" flags && lib.elem "--node-taint=sammasak.dev/intermittent=true:NoSchedule" flags) "preserve MSI's worker label and intermittent taint";
        assert expect (!msi.system.autoUpgrade.allowReboot) "keep unattended reboots disabled";
        # #185: a headless host renders no theme; the Qt/Kvantum tree failed MSI's Home Manager activation
        assert expect (!(lib.any (lib.hasPrefix "Kvantum") (lib.attrNames hm.xdg.configFile)) && !msi.stylix.enable && !(hm ? stylix))
          "no Stylix, so no Qt/Kvantum theme, in MSI's Home Manager (no desktop to theme)";
        assert expect (lib.all (n: lib.elem n names) [ "agent-runtime-instance" "agent-runtime-preflight" "agent-runtime-pane" "agent-runtime-herdr" ]) "install the lifecycle, preflight, pane and Herdr adapter tools";
        assert expect msi.sam.profile.devTools "retain the shared Herdr CLI configuration";
        assert expect msi.users.users.${username}.linger "keep the Herdr user service available without an interactive login";
        assert expect (hm.systemd.user.services.herdr.Install.WantedBy == [ "default.target" ]) "declare the per-user Herdr server service";
        assert expect (!msi.sam.herdr.worker.enable) "a runtime host does not grant worker bypass permissions";
        pkgs.runCommand "agent-runtime-msi-pilot" { nativeBuildInputs = [ pkgs.jq ]; } ''
          mkdir $out
          jq -S . ${rt.hostPolicy} > $out/host.json
          jq -S . ${rt.manifestDir}/rust-pilot.json > $out/rust-pilot.json
          grep -Fq 'systemctl stop k3s.service' ${shutdownScript}
          grep -Fq 'sleep 5' ${shutdownScript}
          grep -Fq 'systemctl poweroff' ${shutdownScript}
        '';

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
        assert expect (rt.host.reserve == { cpus = 0; memoryMiB = 4096; diskMiB = 51200; }) "the reserve keeps 4 GiB and 50 GiB free and does not cap host CPUs";
        assert expect (rt.host.allowedMountRoots == [ ]) "no host mounts";
        assert expect (tpl.policies.network == { egress = "none"; allow = [ ]; }) "no network";
        assert expect (tpl.policies.capabilities == [ ] && tpl.policies.privateSources == [ ]) "no credential";
        assert expect (tpl.policies.resources == { cpus = 2; memoryMiB = 3072; tasksMax = 512; timeoutMinutes = 20; }) "the measured budgets";
        assert expect (tpl.filesystem.mounts == [ ]) "no extra mounts";
        assert expect (tpl.sources.factum.writable && tpl.sources.factum.locked.rev == inputs.factum.rev) "factum at the flake's pinned rev, a private writable copy";
        assert expect (lib.all (n: lib.elem n names) [ "agent-runtime-instance" "agent-runtime-preflight" "agent-runtime-pane" "agent-runtime-herdr" ]) "the lifecycle, preflight, pane and Herdr adapter on the host";
        assert expect (others == [ "msi-ms7758" ]) "MSI is the only other enabled runtime host (got ${toString others})";
        # The #169 coder template admitted beside rust-pilot: egress is exactly the Claude API host,
        # no credential, no ANTHROPIC_* auth path in the runner, and admitted on acer-swift and MSI only.
        assert expect (coder.policies.network == { egress = "allowlist"; allow = [ "api.anthropic.com" ]; }) "claude-coder egress is exactly api.anthropic.com (no wildcard, no extra host)";
        assert expect (coder.policies.capabilities == [ ]) "claude-coder grants no capability (no GitHub token)";
        assert expect (!(lib.hasInfix "ANTHROPIC_API_KEY=" runnerText) && !(lib.hasInfix "ANTHROPIC_AUTH_TOKEN=" runnerText)) "claude-coder runner assigns no ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN";
        assert expect (!(lib.hasInfix "apiKeyHelper" runnerText)) "claude-coder runner wires no apiKeyHelper (it would resolve a key from a command, bypassing the subscription-token-only path)";
        assert expect (!(lib.hasInfix "ANTHROPIC_BASE_URL" runnerText)) "claude-coder runner sets no ANTHROPIC_BASE_URL (it would redirect the API to a non-Anthropic host, an egress path outside the allowlist)";
        assert expect (lib.hasInfix "unset ANTHROPIC_API_KEY" runnerText) "claude-coder runner unsets the ANTHROPIC_* auth paths";
        assert expect (othersCoder == [ "msi-ms7758" ]) "MSI is the only other host that admits claude-coder (got ${toString othersCoder})";
        pkgs.runCommand "agent-runtime-acer-pilot" { nativeBuildInputs = [ pkgs.jq ]; } ''
          mkdir $out
          jq -S . ${rt.hostPolicy} > $out/host.json
          jq -S . ${rt.manifestDir}/rust-pilot.json > $out/rust-pilot.json
          jq -S . ${rt.manifestDir}/claude-coder.json > $out/claude-coder.json
        '';
      };
    };
}
