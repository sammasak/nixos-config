# Repo devshell: the tools the Justfile and lint scripts assume on PATH.
{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      # mkShellNoCC: nothing here compiles C; mkShell would drag ~330MB of
      # gcc/binutils/glibc-dev into the shell closure.
      devShells.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          just
          shellcheck
          sops
          age
          jq
          inputs.deploy-rs.packages.${system}.default
        ];
      };
    };
}
