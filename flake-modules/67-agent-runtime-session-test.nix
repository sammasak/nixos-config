{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # The interactive session path (dtach PTY in an instance, non-root attach, the sudo helper)
      # with a stub program; run explicitly: `nix build .#packages.x86_64-linux.agent-runtime-session-test`.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-session-test = import ../tests/agent-runtime-session.nix {
          inherit pkgs lib;
          inherit (inputs) skills;
        };
      };
    };
}
