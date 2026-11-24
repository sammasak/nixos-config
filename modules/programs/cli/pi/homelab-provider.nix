# Pi's `homelab` provider for the llm-gateway (models.json); a worker guest's (modules/workers) points it at its proxy.
{ baseUrl, apiKey }:
{
  inherit baseUrl apiKey;
  api = "openai-completions";
  models = [
    {
      id = "auto";
      name = "homelab auto";
      reasoning = true;
      contextWindow = 1048576;
      maxTokens = 32768;
    }
    {
      id = "best";
      name = "homelab best";
      reasoning = true;
      contextWindow = 1048576;
      maxTokens = 32768;
    }
    {
      id = "local";
      name = "homelab local";
      contextWindow = 131072;
      maxTokens = 8192;
    }
  ];
  # One request shape every tier accepts: msi Ollama 400s on `reasoning_effort`
  # (rejected by both models, so `auto`/`local` lose the local floor) and Gemini
  # on `store`; `system`, not `developer`. x-session-id pins tool loops to a model.
  compat = {
    supportsStore = false;
    supportsReasoningEffort = false;
    supportsDeveloperRole = false;
    maxTokensField = "max_tokens";
    sendSessionAffinityHeaders = true;
    sessionAffinityFormat = "openrouter";
  };
}
