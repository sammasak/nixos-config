"""herman#57: tools/perf-metrics/gate-tests.sh runs no_source_paths from tools/web/web.sh against a dirty and a
clean fixture wasm, asserts the refusal and the pass, and EXPECTED_CHECKS grows to match. Run from the root of a
herman tree."""
import pathlib
import re
import sys

text = pathlib.Path("tools/perf-metrics/gate-tests.sh").read_text()
problems = []
if "no_source_paths" not in text:
    problems.append("gate-tests.sh never names no_source_paths: extract it from $WEBSH and run it")
checks = [line for line in text.splitlines() if re.match(r"\s*check\s", line) and "no_source_paths" in line]
if len(checks) < 2:
    problems.append("want at least two check lines that name no_source_paths (one refuses, one passes)")
if checks and not any(re.search(r'\s1\s+"\$RC"', line) for line in checks):
    problems.append("one no_source_paths check must expect exit 1 for the dirty fixture")
if checks and not any(re.search(r'\s0\s+"\$RC"', line) for line in checks):
    problems.append("one no_source_paths check must expect exit 0 for the clean fixture")
if not re.search(r"/registry/src/|/git/checkouts/|/lib/rustlib/src/rust/|/home/", text):
    problems.append("the dirty fixture must hold one of the refused patterns, such as /registry/src/")
count = re.search(r"^EXPECTED_CHECKS=(\d+)$", text, re.M)
if not count or int(count[1]) < 410:
    problems.append("EXPECTED_CHECKS must grow from 408 by the number of new checks")
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
