#!/usr/bin/env python3
"""Shipping metrics (docs/shipping.md) as one Prometheus textfile: issue flow and PR speed from GitHub's REST API,
gate, deploy and rollback numbers from the platform records in Loki (scripts/platform-record.sh), merge-to-deploy lag
from each host's last good deploy. Read-only calls only. A source that fails leaves its series out (never a 0 in their
place) and keeps the previous success timestamp of its section, so a stale section is visible, not invented. Exits 0
whenever it could write the file: a timer must not turn a GitHub outage into a restart loop.

Usage: shipping-metrics.py --policy FILE --out FILE --owner OWNER --deploy-repo REPO --loki URL --hostnames a,b
       shipping-metrics.py --list   (the metric names it can emit, one per line: the build-time check reads them)"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

METRICS = {
    "shipping_collector_success_timestamp_seconds": "Unix time a section last collected without error.",
    "shipping_collector_authenticated": "1 when GitHub calls carried a token (private repos counted), 0 for public only.",
    "shipping_issues_open": "Open issues per repo and class (actionable, parked by policy, archived repo).",
    "shipping_issues_open_labelled": "Open actionable issues carrying the label.",
    "shipping_issues_opened": "Issues opened in the window, all owner repos.",
    "shipping_issues_closed": "Issues closed in the window, all owner repos.",
    "shipping_issue_age_days": "Age of open actionable issues, by quantile.",
    "shipping_prs_merged": "PRs merged in the window.",
    "shipping_pr_lead_time_hours": "Open-to-merge time of PRs merged in the last 7 d, by quantile.",
    "shipping_review_rounds": "Verdict comments (Grade: N/10) per reviewed merged PR, by quantile.",
    "shipping_review_first_pass_ratio": "Share of the last reviewed merged PRs whose first verdict met the policy grade.",
    "shipping_review_prs_counted": "Reviewed merged PRs behind the review ratio and rounds.",
    "shipping_review_unreviewed_prs": "Merged PRs in the review sample with no verdict comment.",
    "shipping_escapes": "Reverts on default branches and issues labelled escape, in the window.",
    "shipping_gate_fail_ratio": "Share of the last push-mode nixos-qa gate runs that failed.",
    "shipping_gate_runs_counted": "Push-mode gate runs behind the fail ratio.",
    "shipping_gate_seconds": "Duration of the last push-mode gate runs, by quantile.",
    "shipping_gate_step_failures": "Failed gate steps in the last 7 d, by step.",
    "shipping_deploys": "Recorded deploys in the last 7 d, by result.",
    "shipping_deploy_rollbacks": "Deploys deploy-rs rolled back, in the window.",
    "shipping_deploy_lag_commits": "Commits on main the host's last good deploy does not have.",
    "shipping_deploy_lag_hours": "Hours since the oldest commit on main the host does not have was made (0 when current).",
}
LABELS = ["needs-live", "needs-decision", "blocked", "approved", "ready-for-agent"]
GRADE = re.compile(r"Grade:\s*(\d+)\s*/\s*10")
LOKI_DAYS = 14  # how far back a host's last good deploy is looked for; Loki keeps the platform stream 720 h
DEADLINE = time.monotonic() + 240  # the unit's TimeoutStartSec is above this; a slow API ends a run, not the timer


class Out:
    def __init__(self):
        self.lines = {}

    def add(self, name, value, **labels):
        assert name in METRICS, f"{name} is not in METRICS"
        lab = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        self.lines.setdefault(name, []).append(f"{name}{{{lab}}} {value:.15g}" if lab else f"{name} {value:.15g}")

    def text(self):
        body = []
        for name, rows in self.lines.items():
            body += [f"# HELP {name} {METRICS[name]}", f"# TYPE {name} gauge", *rows]
        return "\n".join(body) + "\n"


class GitHub:
    # seconds between search calls, with and without a token: the search API allows 30 and 10 a minute
    pace = (2.1, 6.5)

    def __init__(self, api, token):
        self.api, self.token, self.last_search = api, token, 0.0

    def get(self, path, **params):
        if time.monotonic() > DEADLINE:
            raise TimeoutError("run deadline reached")
        if path.startswith("/search/"):
            wait = self.pace[0 if self.token else 1] - (time.monotonic() - self.last_search)
            if wait > 0:
                time.sleep(wait)
            self.last_search = time.monotonic()
        url = self.api + path + ("?" + urllib.parse.urlencode(params) if params else "")
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "shipping-metrics"})
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    def search(self, kind, q, limit=1000):
        """Every item of a search, up to limit (GitHub serves at most 1000), and the total count."""
        items, page, total = [], 1, 0
        while True:
            r = self.get(f"/search/{kind}", q=q, per_page=100, page=page)
            total = r["total_count"]
            items += r["items"]
            if len(r["items"]) < 100 or len(items) >= min(total, limit):
                return items, total
            page += 1

    def count(self, q):
        return self.get("/search/issues", q=q, per_page=1)["total_count"]


def quantile(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def repo_of(item):
    return item["repository_url"].rsplit("/", 1)[1]


def issues(gh, out, owner, parked, now):
    repos, page = [], 1
    while page == 1 or len(repos) == 100 * (page - 1):
        path, extra = ("/user/repos", {"affiliation": "owner"}) if gh.token else (f"/users/{owner}/repos", {"type": "owner"})
        repos += gh.get(path, per_page=100, page=page, **extra)
        page += 1
    archived = {r["name"] for r in repos if r["archived"]}
    items, _ = gh.search("issues", f"user:{owner} is:issue is:open")
    by = {}
    actionable = []
    for it in items:
        repo = repo_of(it)
        cls = "archived" if repo in archived else "parked" if repo in parked else "actionable"
        by[(repo, cls)] = by.get((repo, cls), 0) + 1
        if cls == "actionable":
            actionable.append(it)
    for (repo, cls), n in sorted(by.items()):
        out.add("shipping_issues_open", n, repo=repo, **{"class": cls})
    for label in LABELS:
        out.add("shipping_issues_open_labelled", sum(label in {x["name"] for x in it["labels"]} for it in actionable), label=label)
    ages = [(now - ts(it["created_at"])).total_seconds() / 86400 for it in actionable]
    for q in (0.5, 0.9):
        if ages:
            out.add("shipping_issue_age_days", quantile(ages, q), quantile=str(q))
    for window, delta in (("24h", timedelta(hours=24)), ("7d", timedelta(days=7))):
        since = (now - delta).strftime("%Y-%m-%dT%H:%M:%SZ")
        out.add("shipping_issues_opened", gh.count(f"user:{owner} is:issue created:>={since}"), window=window)
        out.add("shipping_issues_closed", gh.count(f"user:{owner} is:issue closed:>={since}"), window=window)


def prs(gh, out, owner, now):
    since = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    items, total = gh.search("issues", f"user:{owner} is:pr is:merged merged:>={since}")
    out.add("shipping_prs_merged", total, window="7d")
    lead = [(ts(it["pull_request"]["merged_at"]) - ts(it["created_at"])).total_seconds() / 3600 for it in items]
    for q in (0.5, 0.9):
        if lead:
            out.add("shipping_pr_lead_time_hours", quantile(lead, q), quantile=str(q))
    return sorted(items, key=lambda it: it["pull_request"]["merged_at"], reverse=True)


def reviews(gh, out, merged, want, grade):
    """The last `want` merged PRs with a verdict comment: their rounds and first-pass share. At most 2*want PRs are
    read, one comments call each, so an unreviewed streak cannot spend the rate limit."""
    rounds, first, unreviewed = [], [], 0
    for it in merged[: 2 * want]:
        if len(rounds) == want:
            break
        comments = gh.get(f"/repos/{it['repository_url'].split('/repos/', 1)[1]}/issues/{it['number']}/comments", per_page=100)
        grades = [int(m.group(1)) for c in comments for m in [GRADE.search(c.get("body") or "")] if m]
        if not grades:
            unreviewed += 1
            continue
        rounds.append(len(grades))
        first.append(grades[0] >= grade)
    out.add("shipping_review_prs_counted", len(rounds))
    out.add("shipping_review_unreviewed_prs", unreviewed)
    if rounds:
        out.add("shipping_review_first_pass_ratio", sum(first) / len(first))
        for q in (0.5, 0.9):
            out.add("shipping_review_rounds", quantile(rounds, q), quantile=str(q))


def escapes(gh, out, owner, now):
    since7 = now - timedelta(days=7)
    stamp = since7.strftime("%Y-%m-%dT%H:%M:%SZ")
    # commit search sees default branches only, which is what a revert on main means here
    reverts, _ = gh.search("commits", f'user:{owner} committer-date:>={stamp} "Revert"')
    reverts = [ts(c["commit"]["committer"]["date"]) for c in reverts if c["commit"]["message"].startswith('Revert "')]
    labelled, _ = gh.search("issues", f"user:{owner} label:escape created:>={stamp}")
    labelled = [ts(i["created_at"]) for i in labelled]
    for window, cut in (("24h", now - timedelta(hours=24)), ("7d", since7)):
        out.add("shipping_escapes", sum(t >= cut for t in reverts), kind="revert", window=window)
        out.add("shipping_escapes", sum(t >= cut for t in labelled), kind="label", window=window)


def loki_records(loki, query, days, enough=None):
    """Platform records newest first, one day per query (the Pi answers a day in seconds and two weeks not at all),
    until `enough(records)` holds or `days` are read."""
    recs, end = [], time.time()
    for _ in range(days):
        if time.monotonic() > DEADLINE:
            raise TimeoutError("run deadline reached")
        params = {"query": query, "start": int((end - 86400) * 1e9), "end": int(end * 1e9), "limit": 5000, "direction": "backward"}
        with urllib.request.urlopen(f"{loki}/loki/api/v1/query_range?{urllib.parse.urlencode(params)}", timeout=30) as r:
            vals = [v for s in json.load(r)["data"]["result"] for v in s["values"]]
        recs += [(int(t) / 1e9, dict(kv.split("=", 1) for kv in line.split() if "=" in kv)) for t, line in sorted(vals, reverse=True)]
        end -= 86400
        if enough and enough(recs):
            break
    return recs


def gates(loki, out, want):
    runs = loki_records(loki, '{job="platform",kind="gate"} |= "mode=push"', 14, lambda r: len(r) >= want)[:want]
    out.add("shipping_gate_runs_counted", len(runs))
    if runs:
        out.add("shipping_gate_fail_ratio", sum(r["result"] != "pass" for _, r in runs) / len(runs))
        secs = [float(r["seconds"]) for _, r in runs if r.get("seconds", "").isdigit()]
        for q in (0.5, 0.9):
            if secs:
                out.add("shipping_gate_seconds", quantile(secs, q), quantile=str(q))
    fails = {}
    for _, r in loki_records(loki, '{job="platform",kind="gate-step"} |= "result=fail"', 7):
        fails[r.get("step", "?")] = fails.get(r.get("step", "?"), 0) + 1
    for step, n in sorted(fails.items()):
        out.add("shipping_gate_step_failures", n, step=step, window="7d")


def node_of(host, hostnames):
    """A deploy record names the flake attribute (lenovo); up{} names the host (lenovo-21CB001PMX)."""
    match = [h for h in hostnames if h == host] or [h for h in hostnames if h.startswith(host + "-")]
    return match[0] if len(match) == 1 else host


def deploys(loki, gh, out, owner, repo, hostnames, now):
    recs = loki_records(loki, '{job="platform",kind="deploy"}', LOKI_DAYS,
                        lambda r: set(hostnames) <= {node_of(d.get("node", ""), hostnames) for _, d in r if d.get("result") == "ok"})
    week = [d for t, d in recs if t >= now.timestamp() - 7 * 86400]
    by = {}
    for d in week:
        by[d.get("result", "?")] = by.get(d.get("result", "?"), 0) + 1
    for result, n in sorted(by.items()):
        out.add("shipping_deploys", n, result=result, window="7d")
    for window, secs in (("24h", 86400), ("7d", 7 * 86400)):
        out.add("shipping_deploy_rollbacks", sum(d.get("rolled_back") == "1" for t, d in recs if t >= now.timestamp() - secs), window=window)
    last = {}
    for _, d in recs:
        if d.get("result") == "ok" and d.get("sha") and d.get("node"):
            last.setdefault(d["node"], d["sha"])
    for host, sha in sorted(last.items()):
        cmp = gh.get(f"/repos/{owner}/{repo}/compare/{sha}...HEAD")
        commits = cmp["commits"]
        # the oldest merge the host lacks; branch commits behind a merge carry their own, older dates
        merges = [c for c in commits if len(c["parents"]) > 1] or commits
        hours = (now - min(ts(c["commit"]["committer"]["date"]) for c in merges)).total_seconds() / 3600 if commits else 0
        out.add("shipping_deploy_lag_commits", cmp["ahead_by"], host=host, node=node_of(host, hostnames))
        out.add("shipping_deploy_lag_hours", max(hours, 0), host=host, node=node_of(host, hostnames))


def previous_success(path):
    try:
        text = open(path).read()
    except OSError:
        return {}
    return {m.group(1): float(m.group(2)) for m in re.finditer(r'shipping_collector_success_timestamp_seconds\{section="([^"]+)"\} (\S+)', text)}


def token():
    if os.environ.get("GH_TOKEN"):
        return os.environ["GH_TOKEN"]
    try:
        r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--list", action="store_true")
    p.add_argument("--policy")
    p.add_argument("--out")
    p.add_argument("--owner")
    p.add_argument("--deploy-repo")
    p.add_argument("--loki")
    p.add_argument("--hostnames", default="")
    p.add_argument("--github-api", default="https://api.github.com")
    a = p.parse_args(argv)
    if a.list:
        print("\n".join(METRICS))
        return 0
    policy = json.load(open(a.policy))
    hostnames = [h for h in a.hostnames.split(",") if h]
    now = datetime.now(timezone.utc)
    gh = GitHub(a.github_api, token())
    out = Out()
    out.add("shipping_collector_authenticated", 1 if gh.token else 0)
    stamps = previous_success(a.out)

    # each section writes to its own Out, merged only when the whole section succeeded: no partial family
    def section(name, fn):
        part = Out()
        try:
            r = fn(part)
            stamps[name] = time.time()
            for k, rows in part.lines.items():
                out.lines.setdefault(k, []).extend(rows)
            return r
        except (urllib.error.URLError, OSError, KeyError, ValueError, TimeoutError) as e:
            print(f"shipping-metrics: {name} failed, its series are left out: {e!r}", file=sys.stderr)
            return None

    alerts = policy["alerts"]
    section("issues", lambda o: issues(gh, o, a.owner, set(policy["issues"]["parkedRepos"]["value"]), now))
    merged = section("prs", lambda o: prs(gh, o, a.owner, now))
    if merged is not None:
        section("reviews", lambda o: reviews(gh, o, merged, alerts["ReviewFirstPassLow"]["lastVerdicts"]["value"], policy["review"]["passGrade"]["value"]))
    section("escapes", lambda o: escapes(gh, o, a.owner, now))
    section("gates", lambda o: gates(a.loki, o, alerts["GateFailRateHigh"]["lastRuns"]["value"]))
    section("deploys", lambda o: deploys(a.loki, gh, o, a.owner, a.deploy_repo, hostnames, now))
    for name in ("issues", "prs", "reviews", "escapes", "gates", "deploys"):
        if name in stamps:
            out.add("shipping_collector_success_timestamp_seconds", stamps[name], section=name)
    tmp = f"{a.out}.tmp"
    with open(tmp, "w") as f:
        f.write(out.text())
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
