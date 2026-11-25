"""nixos-config docs/local-inference-bench.md: qwen3.5:4b is no longer listed as rejected and absent from asus, since
asus pins it behind homelab.ollama.toolModel.enable and the gateway routes `local` to it. Run from the repo root."""
import pathlib
import sys

text = pathlib.Path("docs/local-inference-bench.md").read_text()
rejected = next((b for b in text.split("\n- ") if b.startswith("**Rejected, not measured:**")), "")
problems = []
if not rejected:
    problems.append("keep the 'Rejected, not measured' bullet for the models that are still rejected")
if "qwen3.5:4b" in rejected:
    problems.append("the 'Rejected, not measured' bullet still names qwen3.5:4b")
if "llama3.1:8b" not in rejected or "gemma3:4b-it-qat" not in rejected:
    problems.append("the bullet must still name llama3.1:8b and gemma3:4b-it-qat")
for needle in ("homelab.ollama.toolModel", "modules/homelab/llm-gateway-asus.toml"):
    if needle not in text:
        problems.append(f"say where qwen3.5:4b is pinned and routed now: name {needle}")
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
