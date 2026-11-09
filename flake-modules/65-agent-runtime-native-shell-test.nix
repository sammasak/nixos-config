{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # devenv-platform#93 mode (a): a pinned repo's own devShell realized on the host, its gate run in
      # an instance; run explicitly: `nix build .#packages.x86_64-linux.agent-runtime-native-shell-test`
      # (acer, heavy lock).
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-native-shell-test = import ../tests/agent-runtime-native-shell.nix {
          inherit pkgs lib;
          rfProto = inputs.rf-proto;
          inherit (inputs) skills;
        };
      };
    };
}
