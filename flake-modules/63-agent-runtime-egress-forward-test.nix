{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # #169: allowlist egress to an off-host endpoint (forwarding + source NAT), and the coder's fast
      # egress probe; run explicitly: `nix build .#packages.x86_64-linux.agent-runtime-egress-forward-test`.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-egress-forward-test = import ../tests/agent-runtime-egress-forward.nix {
          inherit pkgs lib;
          rfProto = inputs.rf-proto;
          inherit (inputs) skills;
        };
      };
    };
}
