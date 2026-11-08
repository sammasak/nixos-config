{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      envJsonPath = builtins.getEnv "AGENT_RUNTIME_DEVENV_ENV_JSON";
      profilePath = builtins.getEnv "AGENT_RUNTIME_DEVENV_PROFILE";
      llmEnvJsonPath = builtins.getEnv "AGENT_RUNTIME_LLM_DEVENV_ENV_JSON";
      llmProfilePath = builtins.getEnv "AGENT_RUNTIME_LLM_DEVENV_PROFILE";
      llmTaskPath = builtins.getEnv "AGENT_RUNTIME_LLM_DEVENV_TASK";
      inputsReady = envJsonPath != "" && profilePath != "";
      llmInputsReady = llmEnvJsonPath != "" && llmProfilePath != "" && llmTaskPath != "";
    in
    {
      # Opt-in, heavy guest-acceptance proofs: the host preparer supplies
      # immutable Devenv outputs to focused NixOS VM packages. Both tests use
      # the existing agent-runtime-instance lifecycle inside nspawn.
      packages =
        (lib.optionalAttrs (system == "x86_64-linux" && inputsReady) {
          agent-runtime-devenv-projection-test = import ../tests/agent-runtime-devenv-projection.nix {
            inherit pkgs lib envJsonPath profilePath;
            skills = inputs.skills;
          };
        })
        // (lib.optionalAttrs (system == "x86_64-linux" && llmInputsReady) {
          agent-runtime-llm-gateway-devenv-projection-test = import ../tests/agent-runtime-llm-gateway-devenv.nix {
            inherit pkgs lib llmEnvJsonPath llmProfilePath llmTaskPath;
            src = inputs."llm-gateway";
            skills = inputs.skills;
          };
        });
    };
}
