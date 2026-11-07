# A tiny native devenv/flake fixture for the #93 experiment: a pinned devShell
# whose toolchain (make, a C compiler, coreutils) is realized host-side and
# projected read-only into the nspawn workspace. The project check builds and
# runs one C program. devShells.<system>.default is the "selected devShell".
{
  description = "devenv-native-fixture";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        # the pinned native toolchain the runtime projects (no hooks run on the host)
        packages = [ pkgs.gnumake pkgs.gcc pkgs.coreutils ];
        # an enterShell hook: it must NEVER run during host realization, only inside the guest
        shellHook = "echo entered > .devenv-shell-hook-ran";
      };
    };
}
