{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      envJsonPath = builtins.getEnv "AGENT_RUNTIME_DEVENV_ENV_JSON";
      profilePath = builtins.getEnv "AGENT_RUNTIME_DEVENV_PROFILE";
      inputsReady = envJsonPath != "" && profilePath != "";
    in
    {
      # Opt-in, heavy guest-acceptance proof: first run the host preparer, then
      # `scripts/test-agent-runtime-devenv-projection.sh` supplies these two
      # immutable paths to the focused NixOS VM package. No new lifecycle is
      # introduced; the package exercises agent-runtime-instance in nspawn.
      packages = lib.optionalAttrs (system == "x86_64-linux" && inputsReady) {
        agent-runtime-devenv-projection-test = import ../tests/agent-runtime-devenv-projection.nix {
          inherit pkgs lib envJsonPath profilePath;
          skills = inputs.skills;
        };
      };
    };
}
