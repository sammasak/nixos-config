# scripts/test-nixos-textfile.py: the generation writer held to the shell version's captured output
# (scripts/fixtures/nixos-textfile-parity.json), and its explicit failures where the shell went quiet.
{ lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        nixos-textfile = pkgs.runCommand "nixos-textfile-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          python3 -I ${../scripts/test-nixos-textfile.py} ${
            lib.getExe (pkgs.callPackage ../pkgs/nixos-textfile/package.nix { })
          } ${../scripts/fixtures/nixos-textfile-parity.json} > $out
          cat $out
        '';
      };
    };
}
