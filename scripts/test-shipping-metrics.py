#!/usr/bin/env python3
"""The shipping collector (scripts/shipping-metrics.py) against a fake GitHub and Loki: open issues split into
actionable, parked (the policy's repos) and archived (the API's flag); the first verdict against the policy grade; a
deploy record's flake attribute joined to its host;
PR lead time from the earliest own author date, with its fallbacks; every section stamped; a deploy-repo PR's phases
from its last commit, its gates and the first deploy that has its merge, cached once final. Then GitHub down: exit 0, no GitHub series
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
    print(("PASS: " if ok else f"FAIL (scripts/{__file__.rsplit('/', 1)[-1]}): ") + what)
    failed += not ok


# whole seconds: iso() drops the fraction, and the phase hours are compared exactly
NOW = float(int(time.time()))


def iso(hours_ago):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - hours_ago * 3600))


def issue(repo, n, hours_ago, labels=(), updated_ago=None):
    return {"repository_url": f"https://api.github.com/repos/sammasak/{repo}", "number": n, "created_at": iso(hours_ago),
            "updated_at": iso(hours_ago if updated_ago is None else updated_ago), "labels": [{"name": x} for x in labels]}


def pr(n, opened, merged):
    return dict(issue("nixos-config", n, opened), pull_request={"merged_at": iso(merged)})


parked = json.loads(POLICY.read_text())["issues"]["parkedRepos"]["value"][0]
idle_hours = json.loads(POLICY.read_text())["alerts"]["OpenIssuesUntouched"]["days"]["value"] * 24
# issue 1 is older than the policy's untouched days but updated since; parked and archived issues never count; skills
# has only a fresh issue
OPEN = [issue("nixos-config", 1, idle_hours + 10, ["needs-live"], 10), issue("nixos-config", 2, idle_hours + 50, ["approved"]),
        issue(parked, 3, idle_hours + 100), issue("old", 4, idle_hours + 1000), issue("skills", 5, 5)]
PRS = [pr(10, 5, 1), pr(11, 30, 2), pr(12, 3, 2.5), pr(13, 4.2, 0.2)]
# PR 10 is a batch: opened 5 h ago, its lanes' commits authored 40 and 20 h ago; PR 11's oldest commit is on its
# second page; PR 12's commits answer 404 (a deleted repo), so it falls back to its open time
COMMITS = {10: [40, 20], 11: [30] * 100 + [60, 31], 13: [3, 2.5]}
COMMENTS = {10: ["Grade: 9/10 (head a)"], 11: ["Grade: 6/10 (head b)", "Grade: 9/10 (head c)"], 12: ["looks fine"],
            13: ["Grade: 9/10 (head d)"]}


def sha(n, i):
    return f"{n:02d}{i:03x}" + "0" * 35


MERGES = {10: "a10" + "0" * 37, 11: "d0000001" + "f" * 32, 13: "a13" + "0" * 37}
# idle, gate, gate_to_merge, retries: PR 10's last commit 20 h ago, its pass at 35 h predates it, fails at 30 h and
# 18 h, then a 1 h pass ending 16 h ago (idle 3, gate 1, to merge 15, 2 retries); PR 11's last commit 31 h ago (its
# first listed 30 h), a 0.5 h pass ending 29 h ago (idle 1.5, to merge 27); PR 13 has no gate
GUEST = "acer-herman"
GATES = [f"gate=nixos-qa seconds={100 + i} result={'fail' if i < 5 else 'pass'} sha=x mode=push deferred=0" for i in range(20)] + [
    (35, f"gate=nixos-qa seconds=600 result=pass sha={sha(10, 0)[:7]} mode=push deferred=0"),
    (30, f"gate=nixos-qa seconds=500 result=fail sha={sha(10, 0)[:7]} mode=push deferred=0"),
    (18, f"gate=nixos-qa seconds=500 result=fail sha={sha(10, 1)[:7]} mode=push deferred=0"),
    (16, f"gate=nixos-qa seconds=3600 result=pass sha={sha(10, 1)[:7]} mode=push deferred=0"),
    (10, "gate=nixos-qa seconds=600 result=pass sha=fffffff mode=push deferred=0"),
    (29, f"gate=nixos-qa seconds=1800 result=pass sha={sha(11, 101)[:7]} mode=push deferred=0")]
# merge_to_deploy: d0000000 (1.5 h ago) predates PR 10's merge, d0000001 is PR 11's merge (1.1 h after it, no
# compare), d0000002 the first after PR 10's that has it (0.5 h); nothing after PR 13's has it (not deployed)
DEPLOYS = ["node=lenovo result=ok seconds=9 rolled_back=0 sha=abc1234",
           "node=acer-swift result=deploy-failed seconds=9 rolled_back=1 sha=def5678"] + [
    (h, f"node=lenovo result=ok seconds=20 rolled_back=0 sha={s}") for h, s in ((1.5, "d0000000"), (0.9, "d0000001"), (0.5, "d0000002"))] + [
    # acer's rollback 3 h ago is handled by its good deploy 2 h ago; the newest one, a second old, is not
    (3, "node=acer-swift result=deploy-failed seconds=9 rolled_back=1"), (2, "node=acer-swift result=ok seconds=9 rolled_back=0")]
# reverts: x (30 h, 7 d only); y reapplied 4 h ago under an edited subject; z reverted on purpose (Escape: no); w open
REVERTS = [('Revert "x"', 30), ('Revert "y in Herdr panes"', 5), ('Revert "z"\n\nWhy: on purpose.\nEscape: no', 3),
           ('Revert "w"', 2)]
REAPPLIES = [('Reapply "y in panes"', 4)]
COMPARE = {(MERGES[10], "d0000000"): "ahead", (MERGES[10], "d0000001"): "behind", (MERGES[10], "d0000002"): "ahead",
           (MERGES[11], "d0000000"): "behind"}
github_up = True
compare_up = True
commit_calls, pull_calls, compare_calls = [], [], []


class Fake(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path.startswith("/loki/"):
            query = q["query"][0]
            lines = (GATES if 'kind="gate"' in query else DEPLOYS if 'kind="deploy"' in query
                     else ["gate=nixos-qa step=lint result=fail"] if 'kind="gate-step"' in query else [])
            span = range(int(q["start"][0]), int(q["end"][0]))
            # a line is i seconds old, a (hours, line) pair that many hours
            stamped = [(NOW - l[0] * 3600, l[1]) if isinstance(l, tuple) else (NOW - i, l) for i, l in enumerate(lines)]
            # the gate records come from two streams: the numbered ones alternate lenovo and a guest, the rest lenovo
            hosts = [("" if i == 19 else GUEST if i % 2 == 0 else "lenovo")
                     if 'kind="gate"' in query and isinstance(l, str) else "lenovo" for i, l in enumerate(lines)]
            streams = {}
            for (t, l), h in zip(stamped, hosts):
                if int(t * 1e9) in span:
                    streams.setdefault(h, []).append([str(int(t * 1e9)), l])
            # a stream with no host label (or an empty one) is read as "unknown"
            body = {"data": {"result": [{"stream": {"job": "platform", **({"host": h} if h else {})}, "values": v}
                                        for h, v in streams.items()]}}
        elif not github_up:
            return self.send_error(503)
        elif u.path in ("/user/repos", "/users/sammasak/repos"):
            body = [{"name": "nixos-config", "archived": False}, {"name": parked, "archived": False}, {"name": "old", "archived": True},
                    {"name": "skills", "archived": False}]
        elif u.path == "/search/issues":
            s = q["q"][0]
            # a closed escape issue (8) is left out by the query's is:open
            items = ([issue("nixos-config", 9, 2, ["escape"])] + ([] if "is:open" in s else [issue("nixos-config", 8, 3, ["escape"])])
                     if "label:escape" in s else OPEN if "is:open" in s else PRS if "is:merged" in s else [])
            body = {"total_count": len(items) if items else (7 if "created:" in s else 4), "items": items}
        elif u.path == "/search/commits":
            items = [{"repository": {"full_name": "sammasak/nixos-config"}, "commit": {"message": msg, "committer": {"date": iso(h)}}}
                     for msg, h in (REAPPLIES if '"Reapply"' in q["q"][0] else REVERTS)]
            body = {"total_count": len(items), "items": items}
        elif m := re.match(r"/repos/sammasak/nixos-config/pulls/(\d+)/commits", u.path):
            commit_calls.append(int(m.group(1)))
            if int(m.group(1)) not in COMMITS:
                return self.send_error(404)
            page = int(q["page"][0])
            n = int(m.group(1))
            body = [{"sha": sha(n, i), "commit": {"author": {"date": iso(h)}, "committer": {"date": iso(h)}}}
                    for i, h in enumerate(COMMITS[n]) if (page - 1) * 100 <= i < page * 100]
        elif m := re.match(r"/repos/sammasak/nixos-config/pulls/(\d+)$", u.path):
            pull_calls.append(int(m.group(1)))
            body = {"merge_commit_sha": MERGES[int(m.group(1))]}
        elif m := re.match(r"/repos/sammasak/nixos-config/issues/(\d+)/comments", u.path):
            body = [{"body": b} for b in COMMENTS[int(m.group(1))]]
        elif u.path == "/repos/sammasak/nixos-config/compare/abc1234...HEAD":
            body = {"ahead_by": 2, "commits": [{"parents": [1, 2], "commit": {"committer": {"date": iso(5)}}},
                                               {"parents": [1], "commit": {"committer": {"date": iso(8)}}}]}
        elif m := re.match(r"/repos/sammasak/nixos-config/compare/(\w+)\.\.\.(\w+)$", u.path):
            compare_calls.append((m.group(1), m.group(2)))
            if not compare_up:
                return self.send_error(500)
            if (m.group(1), m.group(2)) not in COMPARE:
                return self.send_error(404)
            body = {"status": COMPARE[(m.group(1), m.group(2))]}
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


SECTIONS = ("issues", "prs", "reviews", "escapes", "gates", "deploys", "phases")
# step_failures: what RetroDueStepFailsRepeat counts. Records as the gate writes them: the step's own (sha=<short>)
# and, inside the flake check, one per check (check=, head=<full>).
H1, H2, H3 = "a" * 40, "b" * 40, "c" * 40
def rec(line):
    return (0, dict(kv.split("=", 1) for kv in line.split()))
def step_rec(step, head, gate="nixos-qa"):
    return rec(f"gate={gate} step={step} seconds=5 result=fail sha={head[:8]}")
def check_rec(check, head):
    return rec(f"gate=nixos-qa step=nixos-flake-check check={check} owner=msi-ms7758 seconds=9 result=fail head={head} drv=/nix/store/x.drv")
DASH = "checks.x86_64-linux.grafana-dashboards"
check(sm.step_failures([step_rec("alloy-otlp-test", H1), step_rec("alloy-otlp-test", H1)]) == {("alloy-otlp-test", "step"): 1},
      "seeded: a re-run on one head counts once")
check(sm.step_failures([check_rec(DASH, H1), step_rec("nixos-flake-check", H1)]) == {("nixos-flake-check", DASH): 1},
      "seeded: the flake check's own record and its failing check's on one head count once, under the check")
check(sm.step_failures([step_rec("nixos-flake-check", H2)]) == {("nixos-flake-check", "step"): 1},
      "a flake check that failed with no inner check record (an evaluation error) counts at the step")
check(sm.step_failures([step_rec("seventh-host-test", H1, gate="on-demand"), step_rec("seventh-host-test", H2, gate="on-demand")]) == {},
      "seeded: an on-demand check's failures are not the push gate's")
three = [r for h in (H1, H2, H3) for r in (check_rec(DASH, h), step_rec("nixos-flake-check", h))]
check(sm.step_failures(three) == {("nixos-flake-check", DASH): 3},
      "seeded: one inner check failing on three heads counts 3 under that check, which the rule's threshold fires on")
check(sm.step_failures([check_rec(DASH, H1), check_rec("checks.x86_64-linux.deploy-activate-asus-b460m", H2),
                        check_rec("checks.x86_64-linux.vm-test", H3)]) == {("nixos-flake-check", DASH): 1,
      ("nixos-flake-check", "checks.x86_64-linux.deploy-activate-asus-b460m"): 1, ("nixos-flake-check", "checks.x86_64-linux.vm-test"): 1},
      "three different checks on three heads are three units at 1, not the umbrella at 3")
check(sm.step_failures([rec("gate=nixos-qa step=lint result=fail"), rec("gate=nixos-qa step=lint result=fail")]) == {("lint", "step"): 2},
      "a record with no head counts on its own")
check(sm.step_failures([rec("gate=nixos-qa step=lint result=fail sha=none"), rec("gate=nixos-qa step=lint result=fail sha=none"),
                        rec("gate=nixos-qa step=lint result=fail head=none")]) == {("lint", "step"): 3},
      "seeded: head none (NIXOS_QA_HEAD's fallback outside git) is no head: three such records count 3, not 1")
check(sm.step_failures([check_rec(DASH, "none"), step_rec("nixos-flake-check", "none")]) == {("nixos-flake-check", DASH): 1, ("nixos-flake-check", "step"): 1},
      "seeded: an umbrella record with head none is not matched to a check record with head none")
check(sm.step_last_failures([(30, check_rec(DASH, H1)[1]), (20, step_rec("nixos-flake-check", H2)[1]), (10, check_rec(DASH, H2)[1])])
      == {("nixos-flake-check", DASH): 30},
      "seeded: a unit's newest failure is its latest record's time; an umbrella record its inner check explains is not one")


def commit_item(msg, h, repo="nixos-config"):
    return {"repository": {"full_name": f"sammasak/{repo}"}, "commit": {"message": msg, "committer": {"date": iso(h)}}}


# a reapply of a's subject clears a, not the newer b; skills' reapply clears nothing in nixos-config; a reapply older
# than every revert clears none
check(sorted(sm.unhandled_reverts([commit_item('Revert "a"', 6), commit_item('Revert "b"', 5)],
                                  [commit_item('Reapply "a"', 4), commit_item('Reapply "b"', 4, "skills"),
                                   commit_item('Revert "Revert "c""', 9)]))
      == [sm.ts(iso(5))], "seeded: a reapply pairs with its own subject's revert, in its own repo, after it")
# the collector pairs over 30 d: a reapply of an 8-d-old revert finds it and leaves the newer escape counted
check(sm.unhandled_reverts([commit_item('Revert "old"', 8 * 24), commit_item('Revert "new"', 2 * 24)],
                           [commit_item('Reapply "old"', 24)]) == [sm.ts(iso(2 * 24))],
      "seeded: a reapply of a revert older than the 7-d count does not clear a newer escape")

with tempfile.TemporaryDirectory() as tmp:
    out = f"{tmp}/shipping.prom"
    rc, m = run(out)
    check(rc == 0, "a full run exits 0")
    check(m.get('shipping_issues_open{class="actionable",repo="nixos-config"}') == 2
          and m.get(f'shipping_issues_open{{class="parked",repo="{parked}"}}') == 1
          and m.get('shipping_issues_open{class="archived",repo="old"}') == 1,
          "open issues split into actionable, parked (policy) and archived (the API's flag)")
    check(m.get('shipping_issues_open_labelled{label="needs-live"}') == 1, "labels count actionable issues")
    check(m.get('shipping_issues_untouched{repo="nixos-config"}') == 1 and m.get('shipping_issues_untouched{repo="skills"}') == 0
          and not any(k.startswith("shipping_issues_untouched{") and not ("nixos-config" in k or "skills" in k) for k in m),
          "untouched counts actionable issues by their last update, not their age; a repo with none reads 0")
    check(m.get("shipping_review_prs_counted") == 3 and abs(m.get("shipping_review_first_pass_ratio", 0) - 2 / 3) < 1e-9
          and m.get("shipping_review_unreviewed_prs") == 1,
          "first verdict against the policy grade; a PR without a verdict is unreviewed, not a pass")
    check(20.8 < m.get('shipping_pr_lead_time_hours{quantile="0.5"}', 0) < 21.0
          and 52.2 < m.get('shipping_pr_lead_time_hours{quantile="0.9"}', 0) < 52.4,
          "lead time runs from the oldest own commit's author date (second page included), not the PR's open time;"
          " a PR whose commits 404 keeps the section")
    check(m.get('shipping_pr_lead_time_fallbacks{reason="http_error",window="7d"}') == 1
          and m.get('shipping_pr_lead_time_fallbacks{reason="no_commits",window="7d"}') == 0
          and m.get('shipping_pr_lead_time_fallbacks{reason="no_token",window="7d"}') == 0,
          "fallbacks are counted per reason, a 0 written for each reason that did not occur")
    # the last 20 push gates: the guest 10, lenovo 9, one from a stream without a host label (19); fails at 0, 2, 4
    # (the guest) and 1, 3 (lenovo); seconds 100+i
    check(m.get('shipping_gate_runs_counted{host="lenovo"}') == 9 and m.get(f'shipping_gate_runs_counted{{host="{GUEST}"}}') == 10
          and abs(m.get('shipping_gate_fail_ratio{host="lenovo"}', 0) - 2 / 9) < 1e-9 and m.get(f'shipping_gate_fail_ratio{{host="{GUEST}"}}') == 0.3
          and "shipping_gate_fail_ratio" not in m,
          "gate runs and fail ratio over the policy's last runs, per host that ran them")
    check(m.get('shipping_gate_seconds{host="lenovo",quantile="0.5"}') == 109
          and m.get(f'shipping_gate_seconds{{host="{GUEST}",quantile="0.5"}}') == 109,
          "each host's median is its own gates' alone")
    check(m.get('shipping_gate_step_failures{check="step",step="lint",window="7d"}') == 1
          and not any(k.startswith("shipping_gate_step_failures") and 'step="lint"' not in k for k in m),
          "a failed push-gate step from Loki is written with check=\"step\", never an empty check")
    check(abs(m.get('shipping_gate_step_last_failure_timestamp_seconds{check="step",step="lint"}', 0) - NOW) < 1
          and sum(k.startswith("shipping_gate_step_last_failure") for k in m) == 1,
          "the step's newest failure is written beside its count, with the same labels")
    check(m.get('shipping_gate_runs_counted{host="unknown"}') == 1
          and not any('host=""' in k for k in m),
          "a stream without a host label counts as host=\"unknown\", never as an empty host")
    check(m.get('shipping_deploy_lag_commits{host="lenovo",node="lenovo-21CB001PMX"}') == 2
          and 4.9 < m.get('shipping_deploy_lag_hours{host="lenovo",node="lenovo-21CB001PMX"}', 0) < 5.1,
          "a deploy record's flake attribute joins its host; lag hours run from the oldest merge it lacks")
    check(m.get('shipping_deploy_rollbacks{window="24h"}') == 2, "a rolled-back deploy is counted")
    check(m.get('shipping_deploy_rollbacks_open{host="acer-swift",node="acer-swift",window="24h"}') == 1
          and m.get('shipping_deploy_rollbacks_open{host="lenovo",node="lenovo-21CB001PMX",window="24h"}') == 0,
          "an open rollback is one with no good deploy of its host since: acer's older one is handled, lenovo has none")
    check(m.get('shipping_escapes{kind="revert",window="7d"}') == 2 and m.get('shipping_escapes{kind="revert",window="24h"}') == 1,
          "a revert on a default branch is an escape in its window only, unless reapplied since or marked Escape: no")
    check(m.get('shipping_escapes{kind="label",window="24h"}') == 1, "a closed escape issue is handled: open ones count")
    sections = {k for k in m if k.startswith("shipping_collector_success_timestamp_seconds")}
    check(len(sections) == 7, f"every section is stamped ({len(sections)})")
    check(all(m.get(f'shipping_collector_section_failed{{section="{s}"}}') == 0 for s in SECTIONS),
          "a full run writes section_failed 0 for every section")

    def phase(p, q):
        return m.get(f'shipping_pr_phase_hours{{phase="{p}",quantile="{q}"}}')

    def near(x, want):
        return x is not None and abs(x - want) < 1e-9

    check(near(phase("idle", 0.5), 2.25) and near(phase("idle", 0.9), 2.85),
          f"idle runs from the last commit (not the first) to the start of the first pass after it {phase('idle', 0.5)}")
    check(near(phase("gate", 0.5), 0.75) and near(phase("gate", 0.9), 0.95), "gate is the passing gate's seconds")
    check(near(phase("gate_to_merge", 0.5), 21) and near(phase("gate_to_merge", 0.9), 25.8), "gate_to_merge: gate end to merge")
    check(near(phase("merge_to_deploy", 0.5), 0.8) and near(phase("merge_to_deploy", 0.9), 1.04),
          f"merge_to_deploy: to the first good deploy after the merge that has it {phase('merge_to_deploy', 0.5)}")
    check(m.get('shipping_pr_gate_retries{quantile="0.5"}') == 1 and near(m.get('shipping_pr_gate_retries{quantile="0.9"}'), 1.8),
          "retries count the failed push gates on the PR's shas before its pass, not the passes")
    check(all(m.get(f'shipping_pr_phase_prs{{phase="{p}"}}') == 2 for p in sm.PHASES)
          and m.get('shipping_pr_phase_unmatched{reason="no_gate"}') == 1
          and m.get('shipping_pr_phase_unmatched{reason="not_deployed"}') == 1
          and m.get('shipping_pr_phase_unmatched{reason="before_records"}') == 0,
          "a PR with no gate and no deploy yet is unmatched for both; a PR whose commits failed is left out")
    labels = {kv.split("=")[0] for k in m if k.startswith(("shipping_pr_phase", "shipping_pr_gate_retries")) and "{" in k
              for kv in k.split("{")[1].rstrip("}").split(",")}
    check(labels == {"phase", "quantile", "reason"}, f"phase series carry bounded labels only, no PR number or sha {labels}")
    check(sorted(compare_calls) == sorted([(MERGES[10], "d0000001"), (MERGES[10], "d0000002"), (MERGES[11], "d0000000"),
                                           (MERGES[13], "abc1234")]),
          f"one compare per deploy tried, in time order after the merge; a deploy of the merge itself needs none {compare_calls}")

    # PR 10, 11 and 13 are cached with their answer; PR 12's 404 is not, so it alone is read again
    commit_calls.clear(), pull_calls.clear(), compare_calls.clear()
    before = m
    rc, m = run(out)
    check(sorted(set(commit_calls)) == [12] and 20.8 < m.get('shipping_pr_lead_time_hours{quantile="0.5"}', 0) < 21.0,
          f"a second run reads only the PR whose commits failed; the cached ones give the same lead time {sorted(set(commit_calls))}")
    check(pull_calls == [] and compare_calls == [] and all(m.get(k) == v for k, v in before.items() if "pr_phase" in k or "retries" in k),
          f"a second run makes no pulls or compare call for final phases (PR 13's deploy tried once), same values {compare_calls}")
    cache = json.loads(pathlib.Path(f"{tmp}/lead-cache.json").read_text())
    check(sorted(k.split("#")[1].split("@")[0] for k in cache) == ["10", "11", "13"],
          f"the cache keeps final answers only, never an http_error fallback {sorted(cache)}")

    # a cache written before phases: deploy-repo entries without facts are read again, not a crash
    pathlib.Path(f"{tmp}/lead-cache.json").write_text(json.dumps({k: v[:2] for k, v in cache.items()}))
    commit_calls.clear(), pull_calls.clear()
    rc, m = run(out)
    check(sorted(set(commit_calls)) == [10, 11, 12, 13] and sorted(pull_calls) == [10, 11, 13]
          and m.get('shipping_collector_section_failed{section="phases"}') == 0
          and all(m.get(k) == v for k, v in before.items() if "pr_phase" in k or "retries" in k),
          f"an old 2-element entry is a miss: read again within the budget, same phases {sorted(set(commit_calls))}")

    # no compare budget left: PRs that need a compare are not matched this run, and not counted as undeployed
    pathlib.Path(f"{tmp}/phase-cache.json").unlink()
    compare_calls.clear()
    budget, sm.PHASE_BUDGET = sm.PHASE_BUDGET, -1
    rc, m = run(out)
    sm.PHASE_BUDGET = budget
    check(compare_calls == [] and m.get('shipping_pr_phase_prs{phase="merge_to_deploy"}') == 0
          and m.get('shipping_pr_phase_unmatched{reason="not_deployed"}') == 0,
          "past the compare budget no compare call is made, and the unmatched PRs wait for the next run")

    # every merge predates the first deploy record: merge_to_deploy counts none of them, no compare is made, nothing is
    # cached as a final deploy, and they show as before_records, not as undeployed
    pathlib.Path(f"{tmp}/phase-cache.json").unlink()
    compare_calls.clear()
    since, sm.DEPLOY_RECORDS_SINCE = sm.DEPLOY_RECORDS_SINCE, time.time()
    rc, m = run(out)
    sm.DEPLOY_RECORDS_SINCE = since
    kept = json.loads(pathlib.Path(f"{tmp}/phase-cache.json").read_text())
    check(compare_calls == [] and m.get('shipping_pr_phase_prs{phase="merge_to_deploy"}') == 0
          and m.get('shipping_pr_phase_unmatched{reason="before_records"}') == 3
          and m.get('shipping_pr_phase_unmatched{reason="not_deployed"}') == 0 and kept == {}
          and m.get('shipping_pr_phase_prs{phase="gate"}') == 2,
          f"a merge before the first deploy record is before_records: no merge_to_deploy, no compare, no cached deploy {kept}")

    # compare fails: phases alone fails, writes none of its series, the other sections stand
    pathlib.Path(f"{tmp}/phase-cache.json").unlink()
    compare_up = False
    rc, m = run(out)
    compare_up = True
    check(rc == 0 and m.get('shipping_collector_section_failed{section="phases"}') == 1
          and m.get('shipping_collector_section_failed{section="deploys"}') == 0
          and not any("pr_phase" in k or "gate_retries" in k for k in m),
          "a failed compare fails the phases section alone: section_failed 1, no partial phase series")

    # no budget left: an uncached PR is not read, it counts as pending at its open time
    pathlib.Path(f"{tmp}/lead-cache.json").unlink()
    commit_calls.clear()
    budget, sm.LEAD_BUDGET = sm.LEAD_BUDGET, -1
    rc, m = run(out)
    sm.LEAD_BUDGET = budget
    check(commit_calls == [] and m.get('shipping_pr_lead_time_fallbacks{reason="pending",window="7d"}') == 4
          and 3.9 < m.get('shipping_pr_lead_time_hours{quantile="0.5"}', 0) < 4.1,
          "past the lookup budget no commits call is made; those PRs count as pending at their open-to-merge time")

    # the run deadline passed: every section fails, and says so
    deadline, sm.DEADLINE = sm.DEADLINE, time.monotonic() - 1
    rc, m = run(out)
    sm.DEADLINE = deadline
    check(rc == 0 and all(m.get(f'shipping_collector_section_failed{{section="{s}"}}') == 1 for s in SECTIONS),
          "past the run deadline each section writes section_failed 1, so a timeout is a series, not a gap")

    before = m
    github_up = False
    rc, m = run(out)
    check(rc == 0, "GitHub down: still exits 0, no restart loop")
    check(not any(k.startswith(("shipping_issues", "shipping_pr", "shipping_review", "shipping_escapes")) for k in m),
          "GitHub down: no GitHub series, no 0 in their place")
    check(any(k.startswith("shipping_gate_fail_ratio{") for k in m), "GitHub down: the Loki sections are still written")
    stamp = 'shipping_collector_success_timestamp_seconds{section="issues"}'
    check(m.get(stamp) == before[stamp], "GitHub down: the issues section keeps its last success timestamp, so it goes stale")
    check(not any(k.startswith("shipping_deploy_lag") for k in m) and "shipping_deploys" not in str(m.keys()),
          "GitHub down: the deploy section writes nothing partial")
    check(m.get('shipping_collector_section_failed{section="prs"}') == 1
          and m.get('shipping_collector_section_failed{section="reviews"}') == 1
          and m.get('shipping_collector_section_failed{section="phases"}') == 1
          and m.get('shipping_collector_section_failed{section="gates"}') == 0,
          "GitHub down: prs failed, reviews and phases (skipped with it) failed, the Loki gates section did not")


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
check(sm.lead_hours(gh, lead_pr)[:2] == (0, None), "a commit authored after the merge clamps lead time to 0, never negative")
hours, reason, _ = sm.lead_hours(StubGitHub([[]]), lead_pr)
check(abs(hours - 4) < 1e-6 and reason == "no_commits", "a PR listing no commits falls back to open-to-merge, counted as no_commits")
gh = StubGitHub([commits(*[2] * 100), urllib.error.HTTPError("u", 404, "gone", {}, None)])
hours, reason, _ = sm.lead_hours(gh, lead_pr)
check(abs(hours - 4) < 1e-6 and reason == "http_error" and gh.calls == 2,
      "an HTTP error on this PR's commits falls back to open-to-merge for it alone, counted as http_error")
gh = StubGitHub([commits(*[2] * 100), commits(*[2] * 100), commits(*[2] * 100), commits(500)])
hours, reason, _ = sm.lead_hours(gh, lead_pr)
check(abs(hours - 1) < 1e-6 and reason is None and gh.calls == 3, "commits are read for at most 3 pages (GitHub's 250)")
gh = StubGitHub([commits(40)], token="")
hours, reason, _ = sm.lead_hours(gh, lead_pr)
check(abs(hours - 4) < 1e-6 and reason == "no_token" and gh.calls == 0,
      "without a token no commits call is made and lead time is open-to-merge, counted as no_token")

try:
    sm.Out().add("shipping_not_declared", 1)
    check(False, "seeded: a name outside METRICS is refused")
except AssertionError:
    check(True, "seeded: a name outside METRICS is refused")

print(f"{failed} failed")
raise SystemExit(1 if failed else 0)
