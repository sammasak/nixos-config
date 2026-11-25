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
      # Paddock's Qwen3.6-35B-A3B on asus (32768), as measured with Pi (sammasak/paddock asus/ssd-expert-backing, "Pi on
      # the pinned serve"): thinking spent most of the output and broke a compaction summary, and a longer cap only
      # lets the model deliberate. The gateway sends a self-hosted model only what fits 3/4 of its window, counting
      # characters / 4 (llm-gateway router.rs can_take); the slots compact 6144 below this.
      contextWindow = 32768;
      maxTokens = 4096;
      reasoning = false;
      samplingParams.chat_template_kwargs.enable_thinking = false;
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
