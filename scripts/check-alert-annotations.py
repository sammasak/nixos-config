"""The alert annotation contract (docs/alert-runbooks.md): every alert in the given rule files carries a summary, a
description other than its summary, a first diagnostic query and a runbook_url naming a heading in a tracked doc;
a rule file with no alert fails (an empty render would pass unseen). A file given as upstream=FILE (a
kube-prometheus-stack mixin) may instead name upstream's runbook for that alert; one given as records=FILE may hold
recording rules only.
Usage: check-alert-annotations.py DOCS [upstream=|records=]RULES... (DOCS: the repo's docs directory; YAML or JSON)."""
import pathlib
import re
import sys

import yaml

PREFIX = "https://github.com/sammasak/nixos-config/blob/main/docs/"
UPSTREAM = "https://runbooks.prometheus-operator.dev/runbooks/"
REQUIRED = ("summary", "description", "query", "runbook_url")

docs = pathlib.Path(sys.argv[1])
failed = []


def slugs(doc):
    """GitHub's heading anchors: lower case, punctuation dropped, spaces as hyphens."""
    return {re.sub(r"[^\w\- ]", "", m.group(1).strip().lower()).replace(" ", "-")
            for m in re.finditer(r"^#+ (.+)$", doc.read_text(), re.M)}


alerts = 0
for arg in sys.argv[2:]:
    kind, _, f = arg.partition("=") if arg.startswith(("upstream=", "records=")) else ("", "", arg)
    before = alerts
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
            if kind == "upstream" and url.startswith(UPSTREAM):
                if not url.endswith("/" + r["alert"].lower()) or url.count("/") != UPSTREAM.count("/") + 1:
                    failed.append(f"{where}: runbook_url {url} is not upstream's page for {r['alert']}")
                continue
            if not url.startswith(PREFIX):
                failed.append(f"{where}: runbook_url {url} is not a doc under {PREFIX}")
                continue
            path, _, anchor = url[len(PREFIX):].partition("#")
            doc = docs / path
            if not doc.is_file():
                failed.append(f"{where}: runbook_url names docs/{path}, no tracked doc")
            elif not anchor:
                failed.append(f"{where}: runbook_url names no #heading in docs/{path}")
            elif anchor not in slugs(doc):
                failed.append(f"{where}: runbook_url anchor #{anchor} is no heading in docs/{path}")
    if alerts == before and kind != "records":
        failed.append(f"{pathlib.Path(f).name}: no alert")

for line in failed:
    print("FAIL: " + line)
print(f"{alerts} alerts, {len(failed)} failures")
sys.exit(1 if failed else 0)
