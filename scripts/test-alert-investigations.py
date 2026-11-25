#!/usr/bin/env python3
"""alert-investigations (pkgs/alert-investigations) on a fake Alertmanager, Prometheus, Loki, pool and GitHub.

Usage: test-alert-investigations.py EXE, the installed trigger, loaded as a module so the fakes stand in for HTTP and
the commands it runs.
"""

import importlib.machinery
import importlib.util
import json
import sys
import tempfile
import urllib.parse
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("alert_investigations", sys.argv[1])
spec = importlib.util.spec_from_loader("alert_investigations", loader)
assert spec is not None
ai = importlib.util.module_from_spec(spec)
loader.exec_module(ai)

T0 = 1_800_000_000.0
NAME = "NodeSystemdUnitFailed"
REPO = "sammasak/nixos-config"
failures = 0


def check(cond: bool, what: str) -> None:
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    failures += not cond


def alert(name: str, fp: str, since: float, unit: str = "backup.service") -> dict:
    return {
        "labels": {"alertname": name, "node": "acer-swift", "name": unit, "severity": "warning"},
        "annotations": {"summary": f"{unit} failed", "query": 'node_systemd_unit_state{state="failed"} == 1'},
        "startsAt": ai.utc(since),
        "fingerprint": fp,
        "status": {"state": "active"},
    }


class World:
    def __init__(self) -> None:
        self.alerts: list[dict] | None = []
        self.issues: dict[int, dict] = {}
        self.comments: list[tuple[int, str]] = []
        self.started: list[tuple[list[str], str]] = []
        self.sessions: dict[str, dict] = {}
        self.cancelled: list[str] = []
        self.refs: list[str] = []
        self.start_rc = 0
        self.gh_down = False
        self.fetched: list[str] = []

    def fetch(self, url: str) -> str:
        self.fetched.append(url)
        if "/api/v2/alerts" in url:
            if self.alerts is None:
                raise OSError("connection refused")
            return json.dumps(self.alerts)
        if url.startswith("http://prom/api/v1/query?"):
            return json.dumps({"status": "success", "data": {"result": [{"metric": {}, "value": [T0, "1"]}]}})
        if "/loki/api/v1/query_range" in url:
            line = "backup.service: Main process exited, status=1/FAILURE"
            return json.dumps({"data": {"result": [{"values": [["2", line], ["1", "Starting backup"]]}]}})
        raise AssertionError(url)

    def run(self, argv: list[str], stdin: str) -> tuple[int, str, str]:
        if argv[0] == "/fake/exec-pool":
            return self.pool(argv[1:], stdin)
        assert argv[:2] == ["/fake/gh", "api"], argv
        if self.gh_down:
            return 1, "", "HTTP 502"
        return self.gh(argv[2:], stdin)

    def pool(self, args: list[str], stdin: str) -> tuple[int, str, str]:
        if args[0] == "start":
            if self.start_rc:
                return self.start_rc, "", "submit_task: refused"
            task = f"cli-{len(self.started):016x}"
            self.started.append((args, stdin))
            self.sessions[task] = {"task": task, "status": "running", "parked": None, "result": None}
            return 0, task + "\n", ""
        if args[0] == "result":
            return 0, json.dumps(self.sessions[args[1]]), ""
        if args[0] == "cancel":
            self.cancelled.append(args[1])
            self.sessions[args[1]]["status"] = "cancelled"
            return 0, "{}", ""
        raise AssertionError(args)

    def gh(self, args: list[str], stdin: str) -> tuple[int, str, str]:
        method = "POST" if "-f" in args or "-F" in args else "GET"
        if args[0] == "-X":
            method, args = args[1], args[2:]
        path, fields = args[0], dict(a.split("=", 1) for a in args[2::2])
        if path == f"repos/{REPO}/issues" and method == "GET":
            return 0, json.dumps(list(self.issues.values())), ""
        if path == f"repos/{REPO}/issues":
            n = 7 + len(self.issues)
            self.issues[n] = {"number": n, "title": fields["title"], "state": "open", "labels": [fields["labels[]"]]}
            return 0, json.dumps(self.issues[n]), ""
        if path.endswith("/comments"):
            self.comments.append((int(path.split("/")[-2]), stdin))
            return 0, "{}", ""
        if path.startswith(f"repos/{REPO}/issues/"):
            n = int(path.rsplit("/", 1)[1])
            if method == "PATCH":
                self.issues[n]["state"] = fields["state"]
            return 0, json.dumps(self.issues[n]), ""
        if "/git/matching-refs/heads/" in path:
            want = "refs/heads/" + path.split("/git/matching-refs/heads/", 1)[1]
            return 0, json.dumps([{"ref": r} for r in self.refs if r.startswith(want)]), ""
        raise AssertionError(args)


def series(out: Path) -> dict[str, float]:
    return {
        line.rsplit(" ", 1)[0]: float(line.rsplit(" ", 1)[1])
        for line in out.read_text().splitlines()
        if line and not line.startswith("#")
    }


def total(out: Path, outcome: str, name: str = NAME) -> float:
    return series(out)[f'homelab_alert_investigations_total{{alertname="{name}",outcome="{outcome}"}}']


def failed(out: Path, reason: str) -> float:
    return series(out)[f'homelab_alert_investigation_failures_total{{alertname="{NAME}",reason="{reason}"}}']


def setup(*extra: str) -> tuple[World, Path, list[str]]:
    d = Path(tempfile.mkdtemp())
    argv = [
        "--alerts", NAME, "--alertmanager", "http://am", "--prometheus", "http://prom", "--loki", "http://loki",
        "--repo", REPO, "--clone-url", f"https://github.com/{REPO}", "--host", "lenovo", "--pool", "/fake/exec-pool",
        "--gh", "/fake/gh", "--state", str(d / "state.json"), "--out", str(d / "out.prom"), *extra,
    ]  # fmt: skip
    return World(), d / "out.prom", argv


def tick(w: World, argv: list[str], at: float) -> int:
    rc: int = ai.main(argv, run=w.run, fetch=w.fetch, now=at)
    return rc


# one firing through the loop: wait 15 minutes, start, report, never twice for the same firing
w, out, argv = setup("--max-per-day", "10")
w.alerts = [alert(NAME, "aa01", T0), alert("TargetDown", "bb02", T0)]
check(tick(w, argv, T0 + 600) == 0 and not w.started, "a firing of 10 minutes starts nothing")
check(total(out, "started") == 0 and total(out, "failed") == 0, "the switched-on name's series exist at 0 before any start")
check(series(out)["homelab_alert_investigations_up"] == 1, "up 1 after a run that read Alertmanager")
tick(w, argv, T0 + 960)
check(len(w.started) == 1, "after 15 minutes one session is started")
args, text = w.started[0]
check(
    args[:9] == ["start", "--agent", "claude", "--repo", f"https://github.com/{REPO}", "--rev", "main", "--workdir", "."]
    and args[args.index("--key") + 1] == f"alert-investigation:{NAME}:aa01@{int(T0)}"
    and args[-2:] == ["--prompt-file", "-"],
    "exec-pool start: claude, the repo at main, a key per firing, the prompt on stdin",
)
check(
    "read only" in text and "push" in text and "deploy" in text and "subagent_type incident-investigator" in text,
    "the prompt is read-only and names the incident-investigator role",
)
check(
    "Main process exited" in text and '"value": [' in text and "up{" in text,
    "the prompt holds the journal and the Prometheus evidence",
)
check("TargetDown" not in text, "an alert not switched on is neither started nor in the evidence")
check(list(w.issues) == [7] and w.issues[7]["title"] == f"Alert: {NAME}", "the issue is created once, titled for the name")
check(f"issues/7" in text, "the prompt names the issue the report goes to")
check(total(out, "started") == 1 and series(out)[f'homelab_alert_investigations_open{{alertname="{NAME}"}}'] == 1, "started 1, open 1")
check("cli-" not in out.read_text() and "aa01" not in out.read_text(), "no session id or fingerprint in the textfile")
tick(w, argv, T0 + 1080)
check(len(w.started) == 1, "a running investigation blocks a second start")
task = "cli-0000000000000000"
w.sessions[task].update(status="waiting", parked="turn_end", result={"output": "## Verdict\nobserved", "branch": None})
tick(w, argv, T0 + 1200)
check(w.comments[-1][0] == 7 and "## Verdict\nobserved" in w.comments[-1][1], "the report lands as a comment on the issue")
check(total(out, "reported") == 1 and series(out)[f'homelab_alert_investigations_open{{alertname="{NAME}"}}'] == 0, "reported 1, open 0")
tick(w, argv, T0 + 1500)
check(len(w.started) == 1, "the same firing, still active, is not investigated again")

# it resolves and fires again: a new session, the same (closed, so reopened) issue
w.alerts = []
tick(w, argv, T0 + 1600)
w.issues[7]["state"] = "closed"
w.alerts = [alert(NAME, "aa01", T0 + 2000)]
tick(w, argv, T0 + 2000 + 901)
check(len(w.started) == 2 and list(w.issues) == [7], "a new firing starts a new session on the same issue")
check(w.issues[7]["state"] == "open", "a closed issue for the name is reopened")

# a session that pushed its branch fails, with its report kept
task = "cli-0000000000000001"
w.refs = [f"refs/heads/pool/{task}"]
w.sessions[task].update(status="waiting", parked="turn_end", result={"output": "report", "branch": None})
tick(w, argv, T0 + 4000)
check(failed(out, "pushed") == 1 and total(out, "failed") == 1, "a pushed branch fails the investigation")
check("**failed**" in w.comments[-1][1] and "report" in w.comments[-1][1], "the issue says so, with the report")

# a parked turn that is not over (a continue after an error) stays open; past the timeout it is cancelled
w.alerts = [alert(NAME, "cc03", T0 + 5000, "other.service")]
tick(w, argv, T0 + 6000)
task = "cli-0000000000000002"
check(len(w.started) == 3, "another unit's firing is its own investigation")
w.sessions[task].update(status="waiting", parked="turn_error")
tick(w, argv, T0 + 7000)
check(total(out, "failed") == 1 and not w.cancelled, "a turn_error park waits for its continue")
tick(w, argv, T0 + 6000 + 10801)
check(w.cancelled == [task] and failed(out, "timed_out") == 1, "past the turn timeout it is cancelled and failed")

# GitHub down while a report waits: it stays open and is posted on the next run
w.alerts = [alert(NAME, "dd04", T0 + 20000)]
tick(w, argv, T0 + 21000)
task = "cli-0000000000000003"
w.sessions[task].update(status="waiting", parked="turn_end", result={"output": "late report", "branch": None})
w.gh_down = True
tick(w, argv, T0 + 21100)
check(total(out, "reported") == 1 and series(out)[f'homelab_alert_investigations_open{{alertname="{NAME}"}}'] == 1, "a failed comment keeps it open")
w.gh_down = False
tick(w, argv, T0 + 21200)
check(total(out, "reported") == 2 and "late report" in w.comments[-1][1], "the next run posts it")

w.sessions["cli-0000000000000003"]["status"] = "failed"
w.alerts = [alert(NAME, "ee05", T0 + 22000)]
tick(w, argv, T0 + 23000)
w.sessions["cli-0000000000000004"].update(status="failed")
tick(w, argv, T0 + 23100)
check(failed(out, "session_failed") == 1, "a failed session fails its investigation")

# the daily cap (3 by default): the fourth firing within 24 h starts nothing, a day later one starts again
w3, out3, argv3 = setup()
for i, at in enumerate((0, 2000, 4000, 6000)):
    w3.alerts = [alert(NAME, f"f{i}", T0 + at)]
    tick(w3, argv3, T0 + at + 901)
    for s in w3.sessions.values():
        s.update(status="waiting", parked="turn_end", result={"output": "r", "branch": None})
    tick(w3, argv3, T0 + at + 950)
check(len(w3.started) == 3 and total(out3, "started") == 3, "three starts in 24 h are the cap")
w3.alerts = [alert(NAME, "f9", T0 + 90000)]
tick(w3, argv3, T0 + 90901)
check(len(w3.started) == 4, "a day later the next firing starts one")

# a refused start counts as started and failed; Alertmanager down is up 0 and keeps every count
w2, out2, argv2 = setup()
w2.alerts = [alert(NAME, "aa01", T0)]
w2.start_rc = 1
tick(w2, argv2, T0 + 1000)
check(total(out2, "started") == 1 and failed(out2, "start_failed") == 1, "a refused start is started and failed")
w2.alerts = None
check(tick(w2, argv2, T0 + 1100) == 1, "Alertmanager unreachable: exit 1")
check(series(out2)["homelab_alert_investigations_up"] == 0 and total(out2, "failed") == 1, "up 0, counts kept")
check(series(out2)["homelab_alert_investigations_success_timestamp_seconds"] == T0 + 1000, "the success time stays")

print(f"{failures} failure(s)")
sys.exit(1 if failures else 0)
