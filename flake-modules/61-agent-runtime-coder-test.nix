{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # #169: the coding-agent template with the real Claude Code binary, offline and model-free in a
      # VM; run explicitly: `nix build .#packages.x86_64-linux.agent-runtime-coder-test` (acer, heavy lock).
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-coder-test = import ../tests/agent-runtime-coder.nix {
          inherit pkgs lib;
          rfProto = inputs.rf-proto;
          inherit (inputs) skills;
        };
      };
    };
}
