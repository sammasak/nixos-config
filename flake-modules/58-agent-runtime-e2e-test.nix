{ lib, inputs, ... }:
{
  # A package, not a check, like the other agent-runtime VM tests: the M4 end-to-end pilot runs on an
  # explicit `nix build .#packages.x86_64-linux.agent-runtime-e2e` (acer, heavy lock). See docs/agent-runtime-runbook.md.
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-e2e = import ../tests/agent-runtime-e2e.nix {
          inherit pkgs lib;
          rfProto = inputs.rf-proto;
          skills = inputs.skills;
        };
      };
    };
}
