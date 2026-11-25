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
      # a tool loop on `local` reaches only asus (32768), and the gateway sends a self-hosted model only what fits 3/4 of
      # its window (llm-gateway router.rs can_take): above this Pi must compact, or the request is refused
      contextWindow = 24576;
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
