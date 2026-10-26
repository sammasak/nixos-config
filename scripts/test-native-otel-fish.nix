{
  nixpkgs,
  devTools ? true,
  nativeOtel ? true,
}:
let
  lib = import (nixpkgs + "/lib");
  pkgs = {
    coreutils = "/stub/coreutils";
    codex = "/stub/codex";
    claude-code = "/stub/claude";
    jq = "/stub/jq";
    herdr = {
      outPath = "/stub/herdr";
      meta.mainProgram = "herdr";
    };
    writeShellApplication = args: "/stub/${args.name}";
  };
  evaluated = lib.evalModules {
    specialArgs = {
      inherit pkgs;
      osConfig.sam.profile.devTools = devTools;
    };
    modules = [
      {
        config._module.check = false;
        options.programs.fish.functions = lib.mkOption {
          type = lib.types.attrsOf lib.types.lines;
        };
      }
    ]
    ++ lib.optional devTools ../modules/programs/cli/herdr
    ++ lib.optional nativeOtel (import ../modules/programs/cli/native-otel.nix "LENOVO-21CB001PMX");
  };
in
evaluated.config.programs.fish.functions
