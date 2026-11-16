"""The coordinator-report job (modules/programs/cli/coordinator-report.sh) without Nix: `date` is pinned to a fixed
day and `devenv` records its argv. fortnight acts on even ISO weeks and renders the weekly of every week since the
previous acting run, that run's week included (three weeks after a 53-week year, so week 52 is not lost); on an odd week, week 09 included (not octal), it exits 0 and never calls devenv. daily runs coord:report:daily."""
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "modules/programs/cli/coordinator-report.sh"
OPTS = ["--option", "coordinator.mayApprove:bool", "true"]
failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def run(tmp, today, mode):
    bin_dir, skills, calls = tmp / "bin", tmp / "skills", tmp / "devenv.calls"
    calls.unlink(missing_ok=True)
    real_date = shutil.which("date")
    (bin_dir / "date").write_text(
        "#!/bin/sh\n"
        f'if [ "$1" = -d ]; then d=$2; shift 2; exec {real_date} -d "$FAKE_TODAY $d" "$@"; fi\n'
        f'exec {real_date} -d "$FAKE_TODAY" "$@"\n')
    (bin_dir / "devenv").write_text(f'#!/bin/sh\nprintf "%s|%s\\n" "$PWD" "$*" >> {calls}\n')
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_TODAY=today,
               COORDINATOR_SKILLS_DIR=str(skills))
    p = subprocess.run(["bash", str(SCRIPT), mode, *OPTS], env=env, capture_output=True, text=True, check=False)
    lines = calls.read_text().splitlines() if calls.exists() else []
    return p, [line.split("|", 1)[1] for line in lines if line.split("|", 1)[0] == str(skills)], len(lines)


def main():
    with tempfile.TemporaryDirectory() as t:
        tmp = pathlib.Path(t)
        (tmp / "bin").mkdir()
        (tmp / "skills").mkdir()
        (tmp / "skills/devenv.nix").write_text("{ }\n")
        opts = " ".join(OPTS)

        for today, weeks in (("2026-11-23", [47, 46]), ("2026-12-21", [51, 50]), ("2027-01-11", [1, 53, 52])):
            p, calls, n = run(tmp, today, "fortnight")
            anchors = [json.loads(c.split("--input-json ", 1)[1].split(" --show-output", 1)[0])["anchor"] for c in calls]
            rendered = [datetime.date.fromisoformat(a).isocalendar().week for a in anchors]
            check(p.returncode == 0 and n == len(weeks) and rendered == weeks
                  and all(c.startswith("tasks run coord:report:weekly --input-json ") and c.endswith(f"--show-output {opts}") for c in calls),
                  f"even week {datetime.date.fromisoformat(today).isocalendar().week} ({today}): the weeklies of weeks {weeks}, "
                  f"in the checkout, with the host's options (exit {p.returncode}, rendered {rendered}, {p.stderr.strip()})")

        for today, week in (("2026-11-16", 47), ("2026-02-23", 9)):
            p, calls, n = run(tmp, today, "fortnight")
            check(p.returncode == 0 and n == 0 and f"ISO week {week} is odd" in p.stdout,
                  f"odd week {week} ({today}): exit 0, devenv never called (exit {p.returncode}, {n} call(s), {p.stderr.strip()})")

        p, calls, n = run(tmp, "2026-11-17", "daily")
        check(p.returncode == 0 and calls == [f"tasks run coord:report:daily --show-output {opts}"],
              f"daily: coord:report:daily with no input (the task's yesterday) and the host's options (got {calls})")

        p, _, n = run(tmp, "2026-11-17", "weekly")
        check(p.returncode == 2 and n == 0, "an unknown mode is a usage error and calls nothing")

        (tmp / "skills/devenv.nix").unlink()
        p, _, n = run(tmp, "2026-11-23", "fortnight")
        check(p.returncode == 0 and n == 0 and "no skills checkout" in p.stdout,
              "an even week without a skills checkout exits 0 and calls nothing")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
