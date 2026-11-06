{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # The #170 authorized-launch wrapper through the real sudo path; a package run explicitly
      # (acer, heavy lock): `nix build .#packages.x86_64-linux.agent-runtime-authorized-launch-test`.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-authorized-launch-test = import ../tests/agent-runtime-authorized-launch.nix {
          inherit pkgs lib;
          inherit (inputs) skills;
        };
      };
    };
}
