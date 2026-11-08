let
  sourcePath = builtins.getEnv "NATIVE_SHELL_TEST_SOURCE";
  project = builtins.getFlake (toString ../.);
  system = "x86_64-linux";
  pkgs = project.inputs.nixpkgs.legacyPackages.${system};
  src =
    if sourcePath == "" then
      throw "native-shell lock-node regression: NATIVE_SHELL_TEST_SOURCE is required"
    else
      builtins.fetchTree {
        type = "path";
        path = sourcePath;
      };
  nativeShell = (import ../modules/agent-runtime/native-shell.nix {
    inherit (pkgs) lib;
    inherit pkgs;
  }) {
    inherit src system;
  };
in
nativeShell.info
