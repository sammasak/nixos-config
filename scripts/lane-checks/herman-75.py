"""herman#75: all_replicas_converge gets its own longer nextest timeout, with a comment saying why, and the default
stays. Run from the root of a herman tree."""
import pathlib
import re
import sys
import tomllib

text = pathlib.Path(".config/nextest.toml").read_text()
conf = tomllib.loads(text)
default = conf["profile"]["default"]
problems = []
if default.get("slow-timeout") != {"period": "120s", "terminate-after": 2}:
    problems.append("the default slow-timeout must stay { period = 120s, terminate-after = 2 }")
mine = [o for o in default.get("overrides", []) if "all_replicas_converge" in o.get("filter", "")]
if len(mine) != 1:
    problems.append("want exactly one [[profile.default.overrides]] whose filter names all_replicas_converge")
else:
    o = mine[0]
    if "herman-replication" not in o["filter"]:
        problems.append("the filter must also name the package herman-replication")
    t = o.get("slow-timeout", {})
    period = re.fullmatch(r"(\d+)s", str(t.get("period", "")))
    if not period or int(period[1]) * int(t.get("terminate-after", 0)) < 480:
        problems.append("its slow-timeout must allow at least 480 s (period in seconds times terminate-after)")
at = text.find("[[profile.default.overrides]]")
block = text[max(at - 400, 0):] if at >= 0 else ""
if "#" not in block or not re.search(r"#.*(busy|load|replica|converge)", block, re.I):
    problems.append("a comment by the override must say why (the test runs about 100 s and hits 240 s on a busy host)")
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
