#!/usr/bin/env python3
"""Shipping metrics (docs/shipping.md) as one Prometheus textfile: issue flow and PR speed from GitHub's REST API,
gate, deploy and rollback numbers from the platform records in Loki (pkgs/platform-record/platform_record.py), merge-to-deploy lag
from each host's last good deploy, and where a deploy-repo PR's time went (phases). Read-only calls only. A source that fails leaves its series out (never a 0 in their
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
    "shipping_issues_untouched": "Open actionable issues per repo with no update for the policy's days.",
    "shipping_prs_merged": "PRs merged in the window.",
    "shipping_pr_lead_time_hours": "Earliest author date of a PR's own commits (its open time without a token) to merge, PRs merged in the last 7 d, by quantile.",
    "shipping_pr_lead_time_fallbacks": "PRs merged in the last 7 d whose lead time fell back to their open time, by reason.",
    "shipping_collector_section_failed": "1 when the section failed this run (an error or the run deadline), else 0.",
    "shipping_review_rounds": "Verdict comments (Grade: N/10) per reviewed merged PR, by quantile.",
    "shipping_review_first_pass_ratio": "Share of the last reviewed merged PRs whose first verdict met the policy grade.",
    "shipping_review_prs_counted": "Reviewed merged PRs behind the review ratio and rounds.",
    "shipping_review_unreviewed_prs": "Merged PRs in the review sample with no verdict comment.",
    "shipping_escapes": "Reverts on default branches not reapplied since and not marked Escape: no, and open issues labelled escape, in the window.",
    "shipping_gate_fail_ratio": "Outstanding failure share of the last full nixos-qa runs, by host: push failures and scheduled failures not superseded by a newer scheduled pass, divided by all sampled full runs. Not historical failure rate or proof of deferred checks.",
    "shipping_gate_runs_counted": "Full gate runs (push or scheduled mode) behind the fail ratio, by host.",
    "shipping_gate_seconds": "Duration of the last full gate runs (push or scheduled mode), by host and quantile.",
    "shipping_gate_step_failures": "Distinct heads a push-gate step (or the flake check's inner check) failed on in the last 7 d, by step and check.",
    "shipping_gate_step_last_failure_timestamp_seconds": "Unix time of the newest of those failures, by step and check.",
    "shipping_gate_step_scheduled_pass_timestamp_seconds": "Unix time a scheduled full gate on main last passed a failed step or check, by step and check.",
    "shipping_deploys": "Recorded deploys in the last 7 d, by result.",
    "shipping_deploy_rollbacks": "Deploys deploy-rs rolled back, in the window.",
    "shipping_deploy_rollbacks_open": "Per host, deploys rolled back in the last 24 h with no good deploy of that host since.",
    "shipping_deploy_lag_commits": "Commits on main the host's last good deploy does not have.",
    "shipping_deploy_lag_hours": "Hours since the oldest commit on main the host does not have was made (0 when current).",
    "shipping_pr_phase_hours": "Hours per phase of deploy-repo PRs merged in the last 7 d, by quantile: idle (last commit to the start of its first passing gate: a full gate, the push hook's fast set or a pool merge check; gate queue wait included: the records carry none), gate, gate_to_merge, merge_to_deploy (to the end of the first good deploy of any host containing the merge).",
    "shipping_pr_phase_prs": "Deploy-repo PRs merged in the last 7 d behind each phase's quantiles.",
    "shipping_pr_gate_retries": "Failed gates (full, fast push set, pool merge check) on a deploy-repo PR's commits before its passing one, PRs merged in the last 7 d, by quantile.",
    "shipping_pr_phase_unmatched": "Deploy-repo PRs merged in the last 7 d with no passing gate on their commits (no_gate), no good deploy containing their merge yet (not_deployed), or merged before deploys were recorded (before_records).",
    "shipping_pr_merge_to_deploy_hours": "Hours from a deploy-repo PR's merge to the end of the host's first good deploy containing it, PRs merged in the last 7 d, by host and quantile.",
    "shipping_pr_merge_to_deploy_prs": "Deploy-repo PRs merged in the last 7 d behind a host's merge_to_deploy quantiles, by host.",
    "shipping_pr_not_deployed": "Deploy-repo PRs merged in the last 7 d (after deploys were recorded) that no good deploy of the host contains yet, by host.",
}
LABELS = ["needs-live", "needs-decision", "blocked", "approved", "ready-for-agent"]
GRADE = re.compile(r"Grade:\s*(\d+)\s*/\s*10")
LOKI_DAYS = 14  # how far back a host's last good deploy is looked for; Loki keeps the platform stream 720 h
DEADLINE = time.monotonic() + 240  # the unit's TimeoutStartSec is above this; a slow API ends a run, not the timer
# seconds a run may spend on commits calls for PRs not yet in the lead cache: a week holds hundreds of merged PRs
# across the owner's repos, one call each, which alone outlast DEADLINE and starve the sections after prs
LEAD_BUDGET = 90
# seconds a run may spend on compare calls matching merges to deploys; a PR left unmatched is tried on the next run
PHASE_BUDGET = 20
PHASES = ("idle", "gate", "gate_to_merge", "merge_to_deploy")
# the first deploy record in Loki (Justfile's deploy, #475): a merge before it has no deploy to find, and the first
# record after it would read as days of merge_to_deploy. Inert once the 7 d window holds no older merge (23 Nov on)
DEPLOY_RECORDS_SINCE = datetime(2026, 11, 16, 12, 53, tzinfo=timezone.utc).timestamp()
# the full gate's runs: by the pre-push hook until it ran the fast set only, then on main by the schedule (scheduled-gate.py)
GATE_QUERY = '{job="platform",kind="gate"} |~ "mode=(push|scheduled)"'
# what a PR passed before its merge (#902): the full gate, the push hook's fast set since 24 Nov (mode=fast, written
# only once that set passed, as result=owed) and the pool's merge check on its head (gate-step records, no gate record)
PHASE_GATE_QUERY = '{job="platform",kind="gate"} |~ "mode=(push|scheduled|fast)"'
STEP_FAIL_QUERY = '{job="platform",kind="gate-step"} |= "result=fail"'
POOL_CHECK_QUERY = '{job="platform",kind="gate-step"} |= "gate=pool-merge-check"'
DEPLOY_QUERY = '{job="platform",kind="deploy"}'
# a run's Loki days by (query, days back): phases re-reads the days gates and deploys fetched; main() empties it
LOKI_READ = {}


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


def issues(gh, out, owner, parked, untouched_days, now):
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
    idle = timedelta(days=untouched_days)
    for repo in sorted({repo_of(it) for it in actionable}):
        out.add("shipping_issues_untouched", sum(repo_of(it) == repo and now - ts(it["updated_at"]) > idle for it in actionable), repo=repo)
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


def lead_hours(gh, it):
    """Hours from the earliest author date among the PR's own commits (those not on its base) to its merge, never
    below 0. The PR's open time stands in when its commits cannot be read: without a token (60 REST calls an hour
    would not cover one call per PR), on an HTTP error for this PR alone (a deleted or private repo), or when it
    lists none. Returns the hours, the fallback's reason (None when the commits gave the start) and the commits read."""
    start, reason, listed = ts(it["created_at"]), "no_token", []
    if gh.token:
        path, page = f"/repos/{it['repository_url'].split('/repos/', 1)[1]}/pulls/{it['number']}/commits", 1
        try:
            while True:
                commits = gh.get(path, per_page=100, page=page)
                listed += commits
                # GitHub lists at most 250 commits of a PR
                if len(commits) < 100 or page == 3:
                    break
                page += 1
        except urllib.error.HTTPError as e:
            print(f"shipping-metrics: commits of {path} unreadable ({e.code}), lead time from its open time", file=sys.stderr)
            listed, reason = [], "http_error"
        else:
            reason = None if listed else "no_commits"
        start = min((ts(c["commit"]["author"]["date"]) for c in listed), default=start)
    return max((ts(it["pull_request"]["merged_at"]) - start).total_seconds() / 3600, 0), reason, listed


def load_cache(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def pr_key(it):
    return f"{it['repository_url']}#{it['number']}@{it['pull_request']['merged_at']}"


def prs(gh, out, owner, deploy_repo, now, cache_path):
    """A merged PR's lead time never changes, so it is read once and kept in the cache file; only a final answer is
    kept (from its commits, or none listed), never a fallback after an error or without a token. New PRs are read
    until LEAD_BUDGET is spent; the rest count as `pending` (open time) and are read on the next runs. A deploy-repo
    PR's entry also keeps what phases() needs, its last commit's time, its shas and its merge commit (one more call);
    an entry without them (written before phases) is read again."""
    since = (now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    items, total = gh.search("issues", f"user:{owner} is:pr is:merged merged:>={since}")
    out.add("shipping_prs_merged", total, window="7d")
    cache, kept, measured = load_cache(cache_path), {}, []
    stop = time.monotonic() + LEAD_BUDGET
    for it in items:
        key, phased, facts = pr_key(it), repo_of(it) == deploy_repo, None
        if key in cache and len(cache[key]) == 2 + phased:
            hours, reason, *rest = cache[key]
            facts = rest[0] if phased else None
        elif time.monotonic() < stop:
            hours, reason, listed = lead_hours(gh, it)
            if phased and reason in (None, "no_commits"):
                try:
                    pull = gh.get(f"/repos/{it['repository_url'].split('/repos/', 1)[1]}/pulls/{it['number']}")
                    last = ts(listed[-1]["commit"]["committer"]["date"]).timestamp() if listed else None
                    facts = {"last": last, "shas": [c["sha"] for c in listed], "merge": pull["merge_commit_sha"]}
                except urllib.error.HTTPError as e:
                    print(f"shipping-metrics: PR {key} unreadable ({e.code}), its phases wait for the next run", file=sys.stderr)
        else:
            hours, reason = max((ts(it["pull_request"]["merged_at"]) - ts(it["created_at"])).total_seconds() / 3600, 0), "pending"
        if reason in (None, "no_commits") and (facts or not phased):
            kept[key] = [hours, reason] + ([facts] if phased else [])
        if facts:
            it["phase_facts"] = facts
        measured.append((hours, reason))
    # only the PRs still in the window: the file stays the size of a week
    with open(f"{cache_path}.tmp", "w") as f:
        json.dump(kept, f)
    os.replace(f"{cache_path}.tmp", cache_path)
    lead = [hours for hours, _ in measured]
    for q in (0.5, 0.9):
        if lead:
            out.add("shipping_pr_lead_time_hours", quantile(lead, q), quantile=str(q))
    # every reason, 0 included: an error that hits every PR shows as a jump, not as a series appearing
    for reason in ("http_error", "no_commits", "no_token", "pending"):
        out.add("shipping_pr_lead_time_fallbacks", sum(r == reason for _, r in measured), reason=reason, window="7d")
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


def subject(c):
    return c["commit"]["message"].split("\n", 1)[0]


def unhandled_reverts(reverts, reapplies):
    """The reverts' times, less those handled: a revert whose message has an `Escape: no` line (reverted on purpose),
    and one a later commit of its repo reapplied (git's `Reapply "X"` or `Revert "Revert "X""`). A reapply pairs with
    the revert of its own subject, else with the newest earlier one of its repo left unpaired: an edited subject still
    clears one revert, never two."""
    open_ = [c for c in reverts if not re.search(r"^Escape:\s*no\s*$", c["commit"]["message"], re.M | re.I)]
    for c in sorted(reapplies, key=lambda c: ts(c["commit"]["committer"]["date"])):
        t, repo = ts(c["commit"]["committer"]["date"]), c.get("repository", {}).get("full_name")
        inner = re.sub(r'^(Reapply|Revert "Revert) "?|"+$', "", subject(c))
        earlier = [r for r in open_ if r.get("repository", {}).get("full_name") == repo
                   and ts(r["commit"]["committer"]["date"]) <= t]
        same = [r for r in earlier if subject(r)[len('Revert "'):].rstrip('"') == inner]
        pick = max(same or earlier, key=lambda r: ts(r["commit"]["committer"]["date"]), default=None)
        if pick is not None:
            open_.remove(pick)
    return [ts(c["commit"]["committer"]["date"]) for c in open_]


def escapes(gh, out, owner, now):
    since7 = now - timedelta(days=7)
    stamp = since7.strftime("%Y-%m-%dT%H:%M:%SZ")
    # reverts and reapplies are paired over 30 d: a reapply of a revert older than the 7-d count must find that one
    pair_stamp = (now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # commit search sees default branches only, which is what a revert on main means here
    found, _ = gh.search("commits", f'user:{owner} committer-date:>={pair_stamp} "Revert"')
    applied, _ = gh.search("commits", f'user:{owner} committer-date:>={pair_stamp} "Reapply"')
    reverts = [c for c in found if subject(c).startswith('Revert "') and not subject(c).startswith('Revert "Revert ')]
    # a commit both searches find is one reapply
    reapplies = list({c.get("sha") or c["commit"]["message"]: c for c in found + applied
                      if subject(c).startswith(('Reapply "', 'Revert "Revert '))}.values())
    reverts = unhandled_reverts(reverts, reapplies)
    # a closed escape issue is a handled one
    labelled, _ = gh.search("issues", f"user:{owner} label:escape is:open created:>={stamp}")
    labelled = [ts(i["created_at"]) for i in labelled]
    for window, cut in (("24h", now - timedelta(hours=24)), ("7d", since7)):
        out.add("shipping_escapes", sum(t >= cut for t in reverts), kind="revert", window=window)
        out.add("shipping_escapes", sum(t >= cut for t in labelled), kind="label", window=window)


def loki_records(loki, query, days, enough=None):
    """Platform records newest first, one day per query (the Pi answers a day in seconds and two weeks not at all),
    until `enough(records)` holds or `days` are read. Each day is fetched once a run (LOKI_READ). A record's "@host" is
    its stream's host label, which the shipper sets (never a field: a logfmt key holds no @); a stream without one is
    "unknown", so its gates still count and show as their own line instead of an unlabelled series."""
    recs, end = [], LOKI_READ.setdefault("end", time.time())
    for day in range(days):
        if (query, day) not in LOKI_READ:
            if time.monotonic() > DEADLINE:
                raise TimeoutError("run deadline reached")
            hi = end - day * 86400
            params = {"query": query, "start": int((hi - 86400) * 1e9), "end": int(hi * 1e9), "limit": 5000, "direction": "backward"}
            with urllib.request.urlopen(f"{loki}/loki/api/v1/query_range?{urllib.parse.urlencode(params)}", timeout=30) as r:
                vals = [(t, line, s["stream"].get("host") or "unknown") for s in json.load(r)["data"]["result"]
                        for t, line in s["values"]]
            LOKI_READ[(query, day)] = [(int(t) / 1e9, {**dict(kv.split("=", 1) for kv in line.split() if "=" in kv),
                                                       "@host": host})
                                       for t, line, host in sorted(vals, reverse=True)]
        recs += LOKI_READ[(query, day)]
        if enough and enough(recs):
            break
    return recs


def gates(loki, out, want):
    """The last `want` full gates, by the host that ran them: a host is compared with its own past (RetroDueGateSlower),
    and a new one, a guest included, does not move another's median."""
    runs = loki_records(loki, GATE_QUERY, 14, lambda r: len(r) >= want)[:want]
    failed = {id(r) for _, r in gate_failures(runs)}
    for host in sorted({r["@host"] for _, r in runs}):
        mine = [r for _, r in runs if r["@host"] == host]
        out.add("shipping_gate_runs_counted", len(mine), host=host)
        out.add("shipping_gate_fail_ratio", sum(id(r) in failed for r in mine) / len(mine), host=host)
        secs = [float(r["seconds"]) for r in mine if r.get("seconds", "").isdigit()]
        for q in (0.5, 0.9):
            if secs:
                out.add("shipping_gate_seconds", quantile(secs, q), host=host, quantile=str(q))
    records = loki_records(loki, STEP_FAIL_QUERY, 7)
    newest = step_last_failures(records)
    for (step, check), n in sorted(step_failures(records).items()):
        out.add("shipping_gate_step_failures", n, step=step, check=check, window="7d")
        out.add("shipping_gate_step_last_failure_timestamp_seconds", newest[step, check], step=step, check=check)
    heads = sorted({head7(r) for _, r in loki_records(loki, GATE_QUERY, 7) if r.get("mode") == "scheduled"} - {""})
    if newest and heads:
        passes = loki_records(loki, '{job="platform",kind="gate-step"} != "result=fail" |~ "(sha|head)=(%s)"' % "|".join(heads), 7)
        for (step, check), t in sorted(step_scheduled_passes(passes, heads, newest).items()):
            out.add("shipping_gate_step_scheduled_pass_timestamp_seconds", t, step=step, check=check)


def gate_failures(runs):
    """The (time, record) runs that count as failed: any not passed, except a scheduled run that a newer scheduled run
    passed. The schedule gates main alone, so its green is that red fixed (ScheduledGateRed named it while it lasted);
    counted on, one red main gated three times a day held the fleet's ratio over the threshold for days after the green,
    as each new run pushes out the window's oldest, a pass."""
    green = max((t for t, r in runs if r.get("mode") == "scheduled" and r.get("result") == "pass"), default=None)
    return [(t, r) for t, r in runs if r.get("result") != "pass"
            and not (r.get("mode") == "scheduled" and green is not None and t < green)]


def step_failures(records):
    """{(step, check): heads} for the push gate's failed records (gate=nixos-qa; an on-demand check is not the gate).
    A unit counts once per head, so a re-run on one head is not a repeat. The flake check is one step over every
    check: its failure counts under the inner check that failed (that check's record, check=), and the step's own
    record only when no inner record failed on the same head (an evaluation error), as check="step": an empty label
    would read as a check that failed unnamed. A record with no head counts on
    its own. Heads compare on 7 hex digits: the step record says sha=<short>, a check record head=<full>. A head that
    is not hex (`none`, NIXOS_QA_HEAD's fallback outside git) is no head: two such records are not one unit."""
    units = {}
    for _, unit, h in step_failure_units(records):
        units.setdefault(unit, set()).add(h)
    return {unit: len(heads) for unit, heads in units.items()}


def step_last_failures(records):
    """{(step, check): unix time} of each unit's newest counted failure, so RetroDueStepFailsRepeat clears a day after
    the last one instead of when the 7-d count drops."""
    newest = {}
    for t, unit, _ in step_failure_units(records):
        newest[unit] = max(t, newest.get(unit, t))
    return newest


def head7(r):
    h = r.get("head") or r.get("sha") or ""
    return h[:7] if re.fullmatch(r"[0-9a-f]{7,64}", h) else ""


def step_scheduled_passes(records, heads, units):
    """{(step, check): unix time} of the newest pass of each failed unit on a scheduled full gate's head (main), so
    RetroDueStepFailsRepeat clears once main passes it again while another step keeps that run red. A check passes by
    its own record only (built, fetched or present): the step's pass says nothing of a check it deferred."""
    newest = {}
    for t, r in records:
        unit = (r.get("step", "?"), r.get("check") or "step")
        ok = ("built", "fetched", "present") if r.get("check") else ("pass",)
        if r.get("gate") == "nixos-qa" and head7(r) in heads and unit in units and r.get("result") in ok:
            newest[unit] = max(t, newest.get(unit, t))
    return newest


def step_failure_units(records):
    """(time, (step, check), head) per failure step_failures counts."""
    fails = [(t, r) for t, r in records if r.get("gate") == "nixos-qa" and r.get("result") == "fail"]
    inner = {(r.get("step"), head7(r)) for _, r in fails if r.get("check") and head7(r)}
    for i, (t, r) in enumerate(fails):
        step, h, check = r.get("step", "?"), head7(r), r.get("check") or "step"
        if not r.get("check") and h and (step, h) in inner:
            continue
        yield t, (step, check), h or f"no-head-{i}"


def node_of(host, hostnames):
    """A deploy record names the flake attribute (lenovo); up{} names the host (lenovo-21CB001PMX)."""
    match = [h for h in hostnames if h == host] or [h for h in hostnames if h.startswith(host + "-")]
    return match[0] if len(match) == 1 else host


def deploy_records(loki, hostnames):
    """The deploy records back to every host's last good deploy, at most LOKI_DAYS."""
    return loki_records(loki, DEPLOY_QUERY, LOKI_DAYS,
                        lambda r: set(hostnames) <= {node_of(d.get("node", ""), hostnames) for _, d in r if d.get("result") == "ok"})


def deploys(loki, gh, out, owner, repo, hostnames, now):
    recs = deploy_records(loki, hostnames)
    week = [d for t, d in recs if t >= now.timestamp() - 7 * 86400]
    by = {}
    for d in week:
        by[d.get("result", "?")] = by.get(d.get("result", "?"), 0) + 1
    for result, n in sorted(by.items()):
        out.add("shipping_deploys", n, result=result, window="7d")
    for window, secs in (("24h", 86400), ("7d", 7 * 86400)):
        out.add("shipping_deploy_rollbacks", sum(d.get("rolled_back") == "1" for t, d in recs if t >= now.timestamp() - secs), window=window)
    # a good deploy of the host after its rollback is the rollback handled: DeployRolledBack reads this one
    good, rolled = {}, {}
    for t, d in recs:
        if d.get("result") == "ok" and d.get("rolled_back") != "1" and d.get("node"):
            good.setdefault(d["node"], t)
    for t, d in recs:
        if d.get("rolled_back") == "1" and d.get("node") and t >= now.timestamp() - 86400 and t > good.get(d["node"], 0):
            rolled[d["node"]] = rolled.get(d["node"], 0) + 1
    for host in sorted(set(good) | set(rolled)):
        out.add("shipping_deploy_rollbacks_open", rolled.get(host, 0), host=host, node=node_of(host, hostnames), window="24h")
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


def contains(gh, owner, repo, merge, sha):
    """Whether deployed commit `sha` has commit `merge`; a sha GitHub does not know (404) has nothing."""
    try:
        return gh.get(f"/repos/{owner}/{repo}/compare/{merge}...{sha}", per_page=1)["status"] in ("ahead", "identical")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        return False


def gate_runs(f, gate_recs, step_fails, pool_recs):
    """The gate runs on a PR's commits as (end, seconds or None, passed), oldest first: a full gate record (mode push or
    scheduled, pass or fail); the push hook's fast record (mode=fast, result=owed, which it writes only once its set
    passed); a push hook whose fast set failed (its nixos-qa-push step record: it writes no gate record then); and a
    pool merge check of the PR head (gate-step records sharing head= the PR head and sha= that run's merge commit: it
    passed when none failed, and ran from its first record's start to its last record)."""
    def mine(r):
        return bool(r.get("sha")) and any(s.startswith(r["sha"]) for s in f["shas"])

    def secs(r):
        return int(r["seconds"]) if r.get("seconds", "").isdigit() else None
    runs = []
    for t, r in gate_recs:
        if not mine(r):
            continue
        if r.get("mode") in ("push", "scheduled") and r.get("result") in ("pass", "fail"):
            runs.append((t, secs(r), r["result"] == "pass"))
        elif r.get("mode") == "fast" and r.get("result") == "owed":
            runs.append((t, secs(r), True))
    runs += [(t, None, False) for t, r in step_fails if r.get("gate") == "nixos-qa-push" and r.get("result") == "fail" and mine(r)]
    checks = {}
    for t, r in pool_recs:
        if f["shas"] and r.get("gate") == "pool-merge-check" and r.get("head") == f["shas"][-1]:
            checks.setdefault(r.get("sha", ""), []).append((t, r))
    for recs in checks.values():
        end = max(t for t, _ in recs)
        begin = min(t - (secs(r) or 0) for t, r in recs)
        runs.append((end, round(end - begin), all(r.get("result") != "fail" for _, r in recs)))
    return sorted(runs, key=lambda x: x[0])


def phases(gh, loki, out, merged, owner, repo, now, cache_path, hostnames):
    """Where a deploy-repo PR's time went, from the facts prs() kept and the gate and deploy records: idle (last
    commit to the start of the first passing gate run on its commits after it, gate_runs(); queue wait included), gate,
    gate_to_merge, merge_to_deploy (to the end of the first good deploy of any host after the merge whose sha has it,
    and per host), and the failed gate runs before the passing one. A host's first deploy that has the merge is kept
    in the cache file, and so are the deployed shas that have it and those that lack it, so no pair is compared twice.
    Compare calls stop at PHASE_BUDGET; a PR left unmatched by it is counted on a later run."""
    known = [(it, it["phase_facts"]) for it in merged if "phase_facts" in it]
    cache, kept = load_cache(cache_path), {}

    def days(times):
        return min(LOKI_DAYS, int((now.timestamp() - min(times)) / 86400) + 1) if times else 0
    back = days([f["last"] for _, f in known if f["last"]])
    gate_recs = loki_records(loki, PHASE_GATE_QUERY, back)
    step_fails = loki_records(loki, STEP_FAIL_QUERY, back)
    pool_recs = loki_records(loki, POOL_CHECK_QUERY, back)
    # a deploy query costs the Pi seconds a day: back to the oldest merge since the deploy records began, as any PR may
    # still lack a host (gates() and deploys() have read most of these days already this run)
    merges = [ts(it["pull_request"]["merged_at"]).timestamp() for it, _ in known]
    deploy_recs = sorted(((t, d) for t, d in loki_records(loki, DEPLOY_QUERY, days([m for m in merges if m >= DEPLOY_RECORDS_SINCE]))
                          if d.get("result") == "ok" and d.get("sha")), key=lambda x: x[0])
    # every host with a good deploy in deploys()'s days (read already), so a host that has deployed none of the PRs
    # still shows, as not_deployed
    nodes = sorted({d["node"] for _, d in deploy_recs + deploy_records(loki, hostnames) if d.get("result") == "ok" and d.get("node")})
    stop = time.monotonic() + PHASE_BUDGET
    hours = {p: [] for p in PHASES}
    by_host = {n: [] for n in nodes}
    not_deployed = {n: 0 for n in nodes}
    retries, unmatched = [], {"no_gate": 0, "not_deployed": 0, "before_records": 0}
    for it, f in known:
        merged_at = ts(it["pull_request"]["merged_at"]).timestamp()
        runs = gate_runs(f, gate_recs, step_fails, pool_recs)
        passed = next(((t, s) for t, s, ok in runs if ok and s is not None and f["last"] <= t <= merged_at), None)
        if passed:
            t, secs = passed
            hours["idle"].append(max(t - secs - f["last"], 0) / 3600)
            hours["gate"].append(secs / 3600)
            hours["gate_to_merge"].append((merged_at - t) / 3600)
            retries.append(sum(not ok for t2, _, ok in runs if t2 < t))
        else:
            unmatched["no_gate"] += 1
        if merged_at < DEPLOY_RECORDS_SINCE:
            unmatched["before_records"] += 1
            continue
        entry = kept[pr_key(it)] = cache.get(pr_key(it), {"deployed": None, "tried": []})
        entry.setdefault("hosts", {})
        entry.setdefault("has", [])
        complete = True
        for t, d in deploy_recs:
            node = d.get("node")
            if t <= merged_at or d["sha"] in entry["tried"] or (entry["deployed"] is not None and (not node or node in entry["hosts"])):
                continue
            if not f["merge"].startswith(d["sha"]) and d["sha"] not in entry["has"]:
                if time.monotonic() > stop:
                    complete = False
                    break
                if not contains(gh, owner, repo, f["merge"], d["sha"]):
                    entry["tried"].append(d["sha"])
                    continue
                entry["has"].append(d["sha"])
            if entry["deployed"] is None:
                entry["deployed"] = t
            if node:
                entry["hosts"].setdefault(node, t)
        if entry["deployed"] is not None:
            hours["merge_to_deploy"].append((entry["deployed"] - merged_at) / 3600)
        elif complete:
            unmatched["not_deployed"] += 1
        for n in nodes:
            if n in entry["hosts"]:
                by_host[n].append((entry["hosts"][n] - merged_at) / 3600)
            elif complete:
                not_deployed[n] += 1
    with open(f"{cache_path}.tmp", "w") as fh:
        json.dump(kept, fh)
    os.replace(f"{cache_path}.tmp", cache_path)
    for p in PHASES:
        out.add("shipping_pr_phase_prs", len(hours[p]), phase=p)
        for q in (0.5, 0.9):
            if hours[p]:
                out.add("shipping_pr_phase_hours", quantile(hours[p], q), phase=p, quantile=str(q))
    for q in (0.5, 0.9):
        if retries:
            out.add("shipping_pr_gate_retries", quantile(retries, q), quantile=str(q))
    for reason, n in unmatched.items():
        out.add("shipping_pr_phase_unmatched", n, reason=reason)
    for n in nodes:
        out.add("shipping_pr_merge_to_deploy_prs", len(by_host[n]), host=n, node=node_of(n, hostnames))
        out.add("shipping_pr_not_deployed", not_deployed[n], host=n, node=node_of(n, hostnames))
        for q in (0.5, 0.9):
            if by_host[n]:
                out.add("shipping_pr_merge_to_deploy_hours", quantile(by_host[n], q), host=n, node=node_of(n, hostnames), quantile=str(q))


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
    LOKI_READ.clear()
    out = Out()
    out.add("shipping_collector_authenticated", 1 if gh.token else 0)
    stamps = previous_success(a.out)
    failed = {}

    # each section writes to its own Out, merged only when the whole section succeeded: no partial family
    def section(name, fn):
        part = Out()
        try:
            r = fn(part)
            stamps[name] = time.time()
            failed[name] = 0
            for k, rows in part.lines.items():
                out.lines.setdefault(k, []).extend(rows)
            return r
        # any error, an unexpected JSON shape included, costs this section alone its update
        except Exception as e:
            print(f"shipping-metrics: {name} failed, its series are left out: {e!r}", file=sys.stderr)
            return None

    alerts = policy["alerts"]
    section("issues", lambda o: issues(gh, o, a.owner, set(policy["issues"]["parkedRepos"]["value"]),
                                       alerts["OpenIssuesUntouched"]["days"]["value"], now))
    state = os.path.dirname(a.out)
    merged = section("prs", lambda o: prs(gh, o, a.owner, a.deploy_repo, now, os.path.join(state, "lead-cache.json")))
    if merged is not None:
        section("reviews", lambda o: reviews(gh, o, merged, alerts["ReviewFirstPassLow"]["lastVerdicts"]["value"], policy["review"]["passGrade"]["value"]))
    section("escapes", lambda o: escapes(gh, o, a.owner, now))
    section("gates", lambda o: gates(a.loki, o, alerts["GateFailRateHigh"]["lastRuns"]["value"]))
    section("deploys", lambda o: deploys(a.loki, gh, o, a.owner, a.deploy_repo, hostnames, now))
    if merged is not None:
        section("phases", lambda o: phases(gh, a.loki, o, merged, a.owner, a.deploy_repo, now, os.path.join(state, "phase-cache.json"), hostnames))
    for name in ("issues", "prs", "reviews", "escapes", "gates", "deploys", "phases"):
        # a section that did not succeed this run failed, a skipped reviews or phases (no prs list) included
        out.add("shipping_collector_section_failed", failed.get(name, 1), section=name)
        if name in stamps:
            out.add("shipping_collector_success_timestamp_seconds", stamps[name], section=name)
    tmp = f"{a.out}.tmp"
    with open(tmp, "w") as f:
        f.write(out.text())
    os.replace(tmp, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
