# deploy-rs push target. lukas keeps password sudo for interactive use; deploys
# log in as `deploy`, whose key is only accepted from lenovo (the sole deployer)
# and whose sudo is passwordless, so pushes need no interactive password.
{ config, lib, ... }:
let
  lenovoKey = lib.findFirst (k: lib.hasSuffix "lukas@lenovo-21CB001PMX" k)
    (throw "deploy-target: lenovo's key is missing from lib/users.nix")
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
      # lenovo's LAN address, plus loopback for its own self-deploy.
      ''from="192.168.10.154,127.0.0.1,::1" ${lenovoKey}''
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
