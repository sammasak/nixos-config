{ lib, inputs, ... }:
{
  # A package, not a check, like 55-agent-runtime-test.nix: three QEMU VMs stay out of
  # nixos:qa and run on an explicit build (acer, heavy lock).
  perSystem =
    { pkgs, system, ... }:
    {
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        agent-runtime-deploy-test = import ../tests/agent-runtime-deploy.nix {
          inherit pkgs lib;
          deployRs = inputs.deploy-rs;
          inherit (inputs) skills;
        };
      };
    };
}
