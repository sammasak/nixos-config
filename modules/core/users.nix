# User configuration with home-manager
{ pkgs, inputs, host, lib, ... }:
let
  vars = import ../../hosts/${host}/variables.nix;
  userDefs = import ../../lib/users.nix;
  inherit (vars)
    username
    terminal
    browser
    shell
    ;
  defaultSshKeys = (userDefs.${username}.sshKeys or [ ]);
  sshAuthorizedKeys = vars.sshAuthorizedKeys or defaultSshKeys;
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

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
        username = "${username}";
        homeDirectory = "/home/${username}";
        stateVersion = "25.11";
        sessionVariables = {
          BROWSER = "${browser}";
          TERMINAL = "${terminal}";
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
      shell = pkgs.${shell};
      ignoreShellProgramCheck = true;
      openssh.authorizedKeys.keys = sshAuthorizedKeys;
    };
  };

  assertions = [
    {
      assertion = sshAuthorizedKeys != [ ];
      message = "No SSH authorized keys configured for `${username}`. Set `lib/users.nix` (${username}.sshKeys) or `hosts/${host}/variables.nix` (sshAuthorizedKeys).";
    }
  ];

  nix.settings = {
    allowed-users = [ "${username}" ];
    trusted-users = [ "root" "${username}" ];
  };
}
