# Headless agent-runtime host (msi-ms7758, acer-swift): the nspawn substrate with the fleet's
# template set, pushed by deploy-rs, unthemed, and with maintenance that stays out of a boot.
# A host adds only its measured capacity (sam.agentRuntime.host) and its hardware facts.
{ config, lib, options, ... }:
let
  desktop = config.sam.desktop.enable;
  runtime = config.sam.agentRuntime.host;
  declaredByHost = opt: opt.highestPrio < (lib.mkOptionDefault null).priority;
in
{
  imports = [
    ./base.nix
    ../core/always-on.nix
    ../homelab/deploy-target.nix
    ../agent-runtime/templates/rust-pilot.nix
    ../agent-runtime/templates/claude-coder.nix
  ];

  sam.agentRuntime.host = {
    enable = true;
    eligibleTemplates = [ "rust-pilot" "claude-coder" ];
  };

  # The coder template's only egress in a live run is the Claude API host; #137 pins the allowlist to
  # the resolved IPs (TLS 443). Without it the template renders egress none and a credentialed run
  # stops at its probe (exit 75).
  sam.agentRuntime.templates.claude-coder.network.allow = [ "api.anthropic.com" ];

  # Delivers the coder run's credential (claude_oauth_token), and nix_access_token.
  sam.hostSecrets.enable = true;

  # Theming only where a desktop boots (#185): headless, Stylix has nothing to theme and its
  # Home Manager half has failed an activation. A desktop specialisation gets it back.
  stylix.enable = lib.mkForce desktop;

  # Calendar timers are ordered after time-sync.target, which without this unit is reached on an
  # unsynchronised clock: a boot with a reset RTC then fires every one of them when NTP steps it.
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "sysinit.target" ];

  # No catch-up run at boot, while k3s and instances start: a missed slot waits for the next one.
  nix.gc.persistent = false;
  nix.optimise.persistent = false;
  system.autoUpgrade.persistent = false;

  # One store-heavy job at a time, should their slots ever meet.
  systemd.services.nix-optimise.after = [ "nix-gc.service" ];
  systemd.services.nixos-upgrade = {
    after = [ "nix-gc.service" "nix-optimise.service" ];
    # notify-send needs a session bus: headless, the hook only adds a failed unit.
    onSuccess = lib.mkIf (!desktop) (lib.mkForce [ ]);
    onFailure = lib.mkIf (!desktop) (lib.mkForce [ ]);
  };

  assertions = [
    {
      assertion = runtime.enable;
      message = "role runtime-host: sam.agentRuntime.host.enable must stay on; drop the role instead.";
    }
    {
      assertion = lib.all declaredByHost (with options.sam.agentRuntime.host; [ maxConcurrentInstances reserve.memoryMiB reserve.diskMiB ]);
      message = "role runtime-host: the host must set sam.agentRuntime.host.maxConcurrentInstances and reserve.{memoryMiB,diskMiB} from its own measurement, not the module defaults.";
    }
    {
      assertion = desktop || !(config.stylix.enable || config.services.displayManager.enable || config.services.xserver.enable);
      message = "role runtime-host: the default boot is headless; Stylix, a display manager or an X server belong in a desktop specialisation (sam.desktop.enable).";
    }
  ];
}
