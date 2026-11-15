{
  config,
  lib,
  pkgs,
  ...
}:
let
  profile = config.sam.profile;
  inherit (profile) username;
  sshAuthorizedKeys = config.sam.userConfig.sshKeys or [ ];
in
{
  programs.dconf.enable = true;

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
      # raw block access reads the SSH host key off the disk, and that key decrypts every secret of the host
      assertion = !lib.elem "disk" config.users.users.${username}.extraGroups;
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
