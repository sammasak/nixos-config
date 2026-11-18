# The platform's side: what one app is approved to have, kept in this repository where the app's own CI cannot write.
# The manifest only requests; admission (admission.nix) refuses any request beyond this.
facts:
{ lib, ... }:
let
  inherit (lib) mkOption types;
  names = import ./names.nix lib;
in
{
  options = {
    owner = mkOption {
      type = types.strMatching names.login;
      description = "The GitHub login approved as answerable for the app.";
    };
    repo = mkOption {
      type = types.strMatching names.repo;
      description = "The one repository (GitHub owner/name) the app may be built from: the allowlist entry.";
    };
    host = mkOption {
      type = types.enum facts.hosts;
      description = "The sam.fleet host the app is placed on.";
    };
    hostnames = mkOption {
      type = types.listOf (types.strMatching names.label);
      default = [ ];
      description = "The labels under the edge's domain the app may serve.";
    };
    secrets = mkOption {
      type = types.listOf (types.strMatching names.secret);
      default = [ ];
      description = "The sops secret names the app may read.";
    };
    memoryMiB = mkOption {
      type = names.memoryMiB;
      default = 256;
      description = "The highest MemoryMax in MiB the app may ask for.";
    };
  };
}
