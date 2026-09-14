{ pkgs, ... }:
{
  # writeShellApplication shellchecks the script at build time.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "dev-init";
      runtimeInputs = [
        pkgs.git
        pkgs.direnv
      ];
      text = builtins.readFile ./dev-init.sh;
    })
  ];
}
