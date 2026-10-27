{ config, lib, pkgs, ... }:
let
  profile = config.sam.profile;
  inherit (profile) username;
  sshAuthorizedKeys = config.sam.userConfig.sshKeys or [ ];
in
{
  programs.dconf.enable = true;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    users.${username} = {
      programs.home-manager.enable = true;
      xdg.enable = true;

      home = {
        username = username;
        homeDirectory = "/home/${username}";
        stateVersion = "25.11";
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
        "disk"
      ];
      shell = pkgs.fish;
      ignoreShellProgramCheck = true;
      openssh.authorizedKeys.keys = sshAuthorizedKeys;
    } // lib.optionalAttrs profile.devTools { linger = true; };
  };

  assertions = [
    {
      assertion = sshAuthorizedKeys != [ ];
      message = "No SSH authorized keys configured for `${username}`. Set `lib/users.nix` (${username}.sshKeys).";
    }
  ];

  nix.settings = {
    allowed-users = [ username ];
    trusted-users = [ "root" "${username}" ];
  };
}
