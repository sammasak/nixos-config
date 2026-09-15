# deploy-rs push targets. lenovo's hostname is localhost: deploy-rs is only
# ever invoked from lenovo itself, so lenovo's own deploy is a loopback
# self-push, used to prove the sudo/magic-rollback path before it is ever
# trusted against acer-swift, which has no BMC.
{ config, inputs, ... }:
{
  flake.deploy.nodes = {
    lenovo = {
      hostname = "localhost";
      profiles.system = {
        sshUser = "lukas";
        user = "root";
        sshOpts = [ "-t" ];
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos config.flake.nixosConfigurations.lenovo;
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 180;
        confirmTimeout = 30;
      };
    };

    acer-swift = {
      hostname = "acer-swift";
      profiles.system = {
        sshUser = "lukas";
        user = "root";
        sshOpts = [ "-t" ];
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos config.flake.nixosConfigurations.acer-swift;
        autoRollback = true;
        magicRollback = true;
        activationTimeout = 180;
        confirmTimeout = 30;
      };
    };
  };

  perSystem =
    { system, ... }:
    {
      checks = inputs.deploy-rs.lib.${system}.deployChecks config.flake.deploy;
    };
}
