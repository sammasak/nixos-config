# deploy-rs push target. lukas keeps password sudo for interactive use; deploys
# log in as `deploy`, whose key is only accepted from lenovo (the sole deployer)
# and whose sudo is passwordless, so pushes need no interactive password.
{ config, lib, ... }:
let
  inherit (config.sam.fleet) deployer;
  deployerKey =
    lib.findFirst (k: lib.hasSuffix "lukas@${deployer}" k)
      (throw "deploy-target: ${deployer}'s key is missing from lib/users.nix")
      (config.sam.userConfig.sshKeys or [ ]);
in
{
  users.groups.deploy = { };
  users.users.deploy = {
    isSystemUser = true;
    group = "deploy";
    # deploy-rs runs its activation through a login shell.
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      # the deployer's LAN address, plus loopback for its own self-deploy.
      ''from="${config.sam.fleet.hosts.${deployer}.address},127.0.0.1,::1" ${deployerKey}''
    ];
  };

  services.openssh.settings.AllowUsers = [ "deploy" ];
  # deploy-rs copies closures (and remote-builds) over ssh-ng as this user.
  nix.settings.allowed-users = [ "deploy" ];

  security.sudo.extraRules = [
    {
      users = [ "deploy" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
