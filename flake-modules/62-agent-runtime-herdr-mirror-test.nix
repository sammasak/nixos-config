{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # #169 option (b): the direct credentialed run made to show in Herdr through a status MIRROR,
      # with no new privilege. Run explicitly (acer, heavy lock):
      # `nix build .#packages.x86_64-linux.agent-runtime-herdr-mirror-test`.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-herdr-mirror-test = import ../tests/agent-runtime-herdr-mirror.nix {
          inherit pkgs lib;
          inherit (inputs) skills;
        };
      };
    };
}
