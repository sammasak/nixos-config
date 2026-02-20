# User configuration with home-manager
{ config, pkgs, lib, ... }:
let
  profile = config.sam.profile;
  inherit (profile) username;
  defaultSshKeys = config.sam.userConfig.sshKeys or [ ];
  sshAuthorizedKeys =
    if profile.sshAuthorizedKeys != [ ]
    then profile.sshAuthorizedKeys
    else defaultSshKeys;
in
{
  programs.dconf.enable = true;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";
    users.${username} = {
      services.hyprpaper.enable = lib.mkOverride 2000 false;
      programs.home-manager.enable = true;
      xdg.enable = true;

      home = {
        username = username;
        homeDirectory = "/home/${username}";
        stateVersion = "25.11";
        sessionVariables = {
          BROWSER = "firefox";
          TERMINAL = "kitty";
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
        "libvirtd"
        "kvm"
        "docker"
        "disk"
      ];
      shell = pkgs.bash;
      ignoreShellProgramCheck = true;
      openssh.authorizedKeys.keys = sshAuthorizedKeys;
    };
  };

  assertions = [
    {
      assertion = sshAuthorizedKeys != [ ];
      message = "No SSH authorized keys configured for `${username}`. Set `lib/users.nix` (${username}.sshKeys) or `sam.profile.sshAuthorizedKeys`.";
    }
  ];

  nix.settings = {
    allowed-users = [ username ];
    trusted-users = [ "root" "${username}" ];
  };
}
