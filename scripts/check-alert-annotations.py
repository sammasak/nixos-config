"""The alert annotation contract (docs/alert-runbooks.md): every alert in the given rule files carries a summary, a
description other than its summary, a first diagnostic query and a runbook_url naming a heading in a tracked doc.
Usage: check-alert-annotations.py DOCS RULES... (DOCS: the repo's docs directory; YAML or JSON rule files)."""
import pathlib
import re
import sys

import yaml

PREFIX = "https://github.com/sammasak/nixos-config/blob/main/docs/"
REQUIRED = ("summary", "description", "query", "runbook_url")

docs = pathlib.Path(sys.argv[1])
failed = []


def slugs(doc):
    """GitHub's heading anchors: lower case, punctuation dropped, spaces as hyphens."""
    return {re.sub(r"[^\w\- ]", "", m.group(1).strip().lower()).replace(" ", "-")
            for m in re.finditer(r"^#+ (.+)$", doc.read_text(), re.M)}


alerts = 0
for f in sys.argv[2:]:
    for group in yaml.safe_load(open(f))["groups"]:
        for r in group["rules"]:
            if "alert" not in r:
                continue
            alerts += 1
            where = f"{pathlib.Path(f).name} {r['alert']}"
            a = r.get("annotations") or {}
            missing = [k for k in REQUIRED if not str(a.get(k, "")).strip()]
            if missing:
                failed.append(f"{where}: no {', '.join(missing)}")
                continue
            if a["description"].strip() == a["summary"].strip():
                failed.append(f"{where}: description repeats the summary")
            url = a["runbook_url"]
            if not url.startswith(PREFIX):
                failed.append(f"{where}: runbook_url {url} is not a doc under {PREFIX}")
                continue
            path, _, anchor = url[len(PREFIX):].partition("#")
            doc = docs / path
            if not doc.is_file():
                failed.append(f"{where}: runbook_url names docs/{path}, no tracked doc")
            elif anchor and anchor not in slugs(doc):
                failed.append(f"{where}: runbook_url anchor #{anchor} is no heading in docs/{path}")

for line in failed:
    print("FAIL: " + line)
print(f"{alerts} alerts, {len(failed)} failures")
sys.exit(1 if failed or not alerts else 0)
