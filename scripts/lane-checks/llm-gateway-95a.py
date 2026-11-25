"""llm-gateway#95, the folded #104 and #105: comments that still describe the old pre-push lint hook are gone, and each file parses to
the same TOML. Run from the root of a llm-gateway tree."""
import json
import pathlib
import sys
import tomllib

PARSED = json.loads('{".config/nextest.toml": {"profile": {"ci": {"retries": 0}, "default": {"slow-timeout": {"period": "60s", "terminate-after": 2}}}}, "rustfmt.toml": {"edition": "2024", "newline_style": "Unix"}}')
STALE = {'rustfmt.toml': ['fmt-check', 'pre-commit'], '.config/nextest.toml': ['dev test']}
KEEP = {'.config/nextest.toml': ['doctest', 'retries']}

problems = []
for path, stale in STALE.items():
    text = pathlib.Path(path).read_text()
    if tomllib.loads(text) != PARSED[path]:
        problems.append(f"{path}: the parsed TOML changed; change comments only")
    comments = "\n".join(line.split("#", 1)[1] for line in text.splitlines() if "#" in line).lower()
    problems += [f"{path}: a comment still says {s!r}" for s in stale if s in comments]
    problems += [f"{path}: keep the note on {k!r}" for k in KEEP.get(path, []) if k not in comments]
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
