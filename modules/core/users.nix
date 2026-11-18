{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config.sam.profile;
  inherit (profile) username;
  sshAuthorizedKeys = config.sam.userConfig.sshKeys;
in
{
  programs.dconf.enable = true;

  # a hand-made user unit in a home shadows the NixOS one, and a deploy then changes nothing for that user: a warning
  # in the activation's output (scripts/shadowed-user-units.sh), after /etc is linked
  system.activationScripts.shadowedUserUnits = {
    deps = [ "etc" ];
    text = ''
      ${pkgs.bash}/bin/bash ${../../scripts/shadowed-user-units.sh} ${
        lib.escapeShellArgs (
          map (u: u.home) (lib.filter (u: u.isNormalUser) (lib.attrValues config.users.users))
        )
      } || true
    '';
  };

  home-manager = {
    users.${username} = {
      programs.home-manager.enable = true;
      xdg.enable = true;

      home = {
        username = username;
        homeDirectory = "/home/${username}";
        sessionVariables = {
          BROWSER = "firefox";
          TERMINAL = "ghostty";
        };
      };
    };
  };

  users = {
    mutableUsers = true;
    users.${username} = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "input"
        "networkmanager"
        "video"
        "audio"
        "kvm"
      ];
      shell = pkgs.fish;
      ignoreShellProgramCheck = true;
      openssh.authorizedKeys.keys = sshAuthorizedKeys;
    }
    // lib.optionalAttrs profile.devTools { linger = true; };
  };

  assertions = [
    {
      assertion = sshAuthorizedKeys != [ ];
      message = "No SSH authorized keys configured for `${username}`. Set `lib/users.nix` (${username}.sshKeys).";
    }
    {
      assertion =
        !lib.elem "disk" config.users.users.${username}.extraGroups
        && !lib.elem username config.users.groups.disk.members;
      message = "`${username}` must not be in the `disk` group: it reads the raw disk, so the host key that decrypts every sops secret. Write disks through sudo.";
    }
  ];

  nix.settings = {
    allowed-users = [ username ];
    trusted-users = [
      "root"
      "${username}"
    ];
  };
}
