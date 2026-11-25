"""llm-gateway#95, its own three files: comments that still describe the old pre-push lint hook are gone, and each file parses to
the same TOML. Run from the root of a llm-gateway tree."""
import json
import pathlib
import sys
import tomllib

PARSED = json.loads('{".cargo/config.toml": {"alias": {"lint": "clippy --profile clippy --workspace --all-targets --locked"}}, "bacon.toml": {"default_job": "lint", "jobs": {"lint": {"command": ["cargo", "lint", "--color", "always"], "need_stdout": false}, "test": {"command": ["cargo", "nextest", "run", "--color", "always"], "need_stdout": true}}, "keybindings": {"l": "job:lint", "t": "job:test"}}, "deny.toml": {"advisories": {"ignore": [], "version": 2, "yanked": "deny"}, "bans": {"allow": [], "allow-wildcard-paths": true, "deny": [], "multiple-versions": "warn", "wildcards": "deny"}, "graph": {"all-features": true}, "licenses": {"allow": ["MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Unicode-3.0", "Unicode-DFS-2016", "Zlib", "MPL-2.0", "BSL-1.0", "CDLA-Permissive-2.0"], "confidence-threshold": 0.9, "version": 2}, "sources": {"allow-registry": ["https://github.com/rust-lang/crates.io-index"], "unknown-git": "deny", "unknown-registry": "deny"}}}')
STALE = {'.cargo/config.toml': ['pre-push', 'dev lint'], 'bacon.toml': ['pre-push'], 'deny.toml': ['pre-push', 'dev lint']}
KEEP = {}

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
