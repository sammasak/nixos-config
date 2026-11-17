#!/usr/bin/env python3
"""The shipping collector (scripts/shipping-metrics.py) against a fake GitHub and Loki: open issues split into
actionable, parked (the policy's repos) and archived (the API's flag); the first verdict against the policy grade; a
deploy record's flake attribute joined to its host;
PR lead time from the earliest own author date, with its fallbacks; every section stamped. Then GitHub down: exit 0, no GitHub series
(no 0 in their place), the Loki sections still written and GitHub's last success timestamps carried over. Seeded: a
name outside METRICS is refused."""
import http.server
import importlib.util
import json
import os
import pathlib
import re
import tempfile
import threading
import time
import urllib.error
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY = ROOT / "modules/homelab/monitoring/shipping-policy.json"
spec = importlib.util.spec_from_file_location("shipping_metrics", ROOT / "scripts/shipping-metrics.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)
sm.GitHub.pace = (0, 0)
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


NOW = time.time()


def iso(hours_ago):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - hours_ago * 3600))


def issue(repo, n, hours_ago, labels=()):
    return {"repository_url": f"https://api.github.com/repos/sammasak/{repo}", "number": n, "created_at": iso(hours_ago),
            "labels": [{"name": x} for x in labels]}


def pr(n, opened, merged):
    return dict(issue("nixos-config", n, opened), pull_request={"merged_at": iso(merged)})


parked = json.loads(POLICY.read_text())["issues"]["parkedRepos"]["value"][0]
OPEN = [issue("nixos-config", 1, 10, ["needs-live"]), issue("nixos-config", 2, 50, ["approved"]),
        issue(parked, 3, 100), issue("old", 4, 1000)]
PRS = [pr(10, 5, 1), pr(11, 30, 2), pr(12, 3, 2.5)]
# PR 10 is a batch: opened 5 h ago, its lanes' commits authored 40 and 20 h ago; PR 11's oldest commit is on its
# second page; PR 12's commits answer 404 (a deleted repo), so it falls back to its open time
COMMITS = {10: [40, 20], 11: [30] * 100 + [60, 31]}
COMMENTS = {10: ["Grade: 9/10 (head a)"], 11: ["Grade: 6/10 (head b)", "Grade: 9/10 (head c)"], 12: ["looks fine"]}
GATES = [f"gate=nixos-qa seconds={100 + i} result={'fail' if i < 5 else 'pass'} sha=x mode=push deferred=0" for i in range(20)]
DEPLOYS = ["node=lenovo result=ok seconds=9 rolled_back=0 sha=abc1234",
           "node=acer-swift result=deploy-failed seconds=9 rolled_back=1 sha=def5678"]
github_up = True


class Fake(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path.startswith("/loki/"):
            query = q["query"][0]
            lines = (GATES if 'kind="gate"' in query else DEPLOYS if 'kind="deploy"' in query
                     else ["gate=nixos-qa step=lint result=fail"] if 'kind="gate-step"' in query else [])
            span = range(int(q["start"][0]), int(q["end"][0]))
            values = [[str(int((NOW - i) * 1e9)), l] for i, l in enumerate(lines) if int((NOW - i) * 1e9) in span]
            body = {"data": {"result": [{"stream": {}, "values": values}]}}
        elif not github_up:
            return self.send_error(503)
        elif u.path in ("/user/repos", "/users/sammasak/repos"):
            body = [{"name": "nixos-config", "archived": False}, {"name": parked, "archived": False}, {"name": "old", "archived": True}]
        elif u.path == "/search/issues":
            s = q["q"][0]
            items = (OPEN if "is:open" in s else PRS if "is:merged" in s else [issue("nixos-config", 9, 2, ["escape"])] if "label:escape" in s else [])
            body = {"total_count": len(items) if items else (7 if "created:" in s else 4), "items": items}
        elif u.path == "/search/commits":
            body = {"total_count": 1, "items": [{"commit": {"message": 'Revert "x"', "committer": {"date": iso(30)}}}]}
        elif m := re.match(r"/repos/sammasak/nixos-config/pulls/(\d+)/commits", u.path):
            if int(m.group(1)) not in COMMITS:
                return self.send_error(404)
            page = int(q["page"][0])
            body = [{"commit": {"author": {"date": iso(h)}}} for h in COMMITS[int(m.group(1))][(page - 1) * 100:page * 100]]
        elif m := re.match(r"/repos/sammasak/nixos-config/issues/(\d+)/comments", u.path):
            body = [{"body": b} for b in COMMENTS[int(m.group(1))]]
        elif u.path == "/repos/sammasak/nixos-config/compare/abc1234...HEAD":
            body = {"ahead_by": 2, "commits": [{"parents": [1, 2], "commit": {"committer": {"date": iso(5)}}},
                                               {"parents": [1], "commit": {"committer": {"date": iso(8)}}}]}
        else:
            return self.send_error(404)
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_port}"
os.environ["GH_TOKEN"] = "fake"


def run(out):
    rc = sm.main(["--policy", str(POLICY), "--out", out, "--owner", "sammasak", "--deploy-repo", "nixos-config",
                  "--loki", url, "--github-api", url, "--hostnames", "lenovo-21CB001PMX,acer-swift"])
    text = pathlib.Path(out).read_text()
    return rc, {l.rsplit(" ", 1)[0]: float(l.rsplit(" ", 1)[1]) for l in text.splitlines() if l and not l.startswith("#")}


with tempfile.TemporaryDirectory() as tmp:
    out = f"{tmp}/shipping.prom"
    rc, m = run(out)
    check(rc == 0, "a full run exits 0")
    check(m.get('shipping_issues_open{class="actionable",repo="nixos-config"}') == 2
          and m.get(f'shipping_issues_open{{class="parked",repo="{parked}"}}') == 1
          and m.get('shipping_issues_open{class="archived",repo="old"}') == 1,
          "open issues split into actionable, parked (policy) and archived (the API's flag)")
    check(m.get('shipping_issues_open_labelled{label="needs-live"}') == 1, "labels count actionable issues")
    check(m.get("shipping_review_prs_counted") == 2 and m.get("shipping_review_first_pass_ratio") == 0.5
          and m.get("shipping_review_unreviewed_prs") == 1,
          "first verdict against the policy grade; a PR without a verdict is unreviewed, not a pass")
    check(38.9 < m.get('shipping_pr_lead_time_hours{quantile="0.5"}', 0) < 39.1
          and 54.1 < m.get('shipping_pr_lead_time_hours{quantile="0.9"}', 0) < 54.3,
          "lead time runs from the oldest own commit's author date (second page included), not the PR's open time;"
          " a PR whose commits 404 keeps the section")
    check(m.get("shipping_gate_fail_ratio") == 0.25 and m.get("shipping_gate_runs_counted") == 20,
          "gate fail ratio over the policy's last runs")
    check(m.get('shipping_deploy_lag_commits{host="lenovo",node="lenovo-21CB001PMX"}') == 2
          and 4.9 < m.get('shipping_deploy_lag_hours{host="lenovo",node="lenovo-21CB001PMX"}', 0) < 5.1,
          "a deploy record's flake attribute joins its host; lag hours run from the oldest merge it lacks")
    check(m.get('shipping_deploy_rollbacks{window="24h"}') == 1, "a rolled-back deploy is counted")
    check(m.get('shipping_escapes{kind="revert",window="7d"}') == 1 and m.get('shipping_escapes{kind="revert",window="24h"}') == 0,
          "a revert on a default branch is an escape in its window only")
    sections = {k for k in m if k.startswith("shipping_collector_success_timestamp_seconds")}
    check(len(sections) == 6, f"every section is stamped ({len(sections)})")
    before = m

    github_up = False
    rc, m = run(out)
    check(rc == 0, "GitHub down: still exits 0, no restart loop")
    check(not any(k.startswith(("shipping_issues", "shipping_pr", "shipping_review", "shipping_escapes")) for k in m),
          "GitHub down: no GitHub series, no 0 in their place")
    check("shipping_gate_fail_ratio" in m, "GitHub down: the Loki sections are still written")
    stamp = 'shipping_collector_success_timestamp_seconds{section="issues"}'
    check(m.get(stamp) == before[stamp], "GitHub down: the issues section keeps its last success timestamp, so it goes stale")
    check(not any(k.startswith("shipping_deploy_lag") for k in m) and "shipping_deploys" not in str(m.keys()),
          "GitHub down: the deploy section writes nothing partial")


class StubGitHub:
    """lead_hours against canned pages: each call pops one; an exception in the list is raised."""

    def __init__(self, pages, token="fake"):
        self.pages, self.token, self.calls = list(pages), token, 0

    def get(self, path, **params):
        self.calls += 1
        page = self.pages.pop(0)
        if isinstance(page, Exception):
            raise page
        return page


def commits(*hours_ago):
    return [{"commit": {"author": {"date": iso(h)}}} for h in hours_ago]


lead_pr = pr(20, 5, 1)  # opened 5 h ago, merged 1 h ago: open-to-merge is 4 h
gh = StubGitHub([commits(0.5)])
check(sm.lead_hours(gh, lead_pr) == 0, "a commit authored after the merge clamps lead time to 0, never negative")
check(abs(sm.lead_hours(StubGitHub([[]]), lead_pr) - 4) < 1e-6, "a PR listing no commits falls back to open-to-merge")
gh = StubGitHub([commits(*[2] * 100), urllib.error.HTTPError("u", 404, "gone", {}, None)])
check(abs(sm.lead_hours(gh, lead_pr) - 4) < 1e-6 and gh.calls == 2,
      "an HTTP error on this PR's commits falls back to open-to-merge for it alone, not an error for the section")
gh = StubGitHub([commits(*[2] * 100), commits(*[2] * 100), commits(*[2] * 100), commits(500)])
check(abs(sm.lead_hours(gh, lead_pr) - 1) < 1e-6 and gh.calls == 3, "commits are read for at most 3 pages (GitHub's 250)")
gh = StubGitHub([commits(40)], token="")
check(abs(sm.lead_hours(gh, lead_pr) - 4) < 1e-6 and gh.calls == 0,
      "without a token no commits call is made and lead time is open-to-merge")

try:
    sm.Out().add("shipping_not_declared", 1)
    check(False, "seeded: a name outside METRICS is refused")
except AssertionError:
    check(True, "seeded: a name outside METRICS is refused")

print(f"{failed} failed")
raise SystemExit(1 if failed else 0)
