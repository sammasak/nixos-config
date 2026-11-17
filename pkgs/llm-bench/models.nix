# Every model the scorecard may name: the tags the fleet's Ollama hosts load (asus pins its tags in
# homelab.ollama.modelDigests) and #493's candidates. flake-modules/llm-bench.nix fails the build when a host loads a
# tag missing here, so a new pin cannot break black-pi's rules at evaluation.
[
  "qwen2.5-coder:7b-instruct-q4_K_M"
  "qwen2.5-coder:7b"
  "qwen2.5-coder:3b"
  "llama3.1:8b"
  "llama3.2:3b"
  "gemma4:e4b-it-qat"
  "gemma4:e2b-it-qat"
  "gemma3:4b-it-qat"
  "qwen3.5:4b"
  "qwen2.5-coder:0.5b"
  "nomic-embed-text:latest"
]
