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
    python3Minimal = "/stub/python3";
    writeShellApplication = args: args // { outPath = "/stub/${args.name}"; };
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
        options.home.packages = lib.mkOption {
          type = lib.types.listOf lib.types.raw;
          default = [ ];
        };
      }
    ]
    ++ lib.optional devTools ../modules/programs/cli/herdr
    ++ lib.optional nativeOtel (import ../modules/programs/cli/native-otel.nix "LENOVO-21CB001PMX");
  };
  codex = lib.filter (p: (p.name or null) == "codex") evaluated.config.home.packages;
in
{
  inherit (evaluated.config.programs.fish) functions;
  codex = map (p: { inherit (p) text; inherit (p.meta) priority; }) codex;
}
