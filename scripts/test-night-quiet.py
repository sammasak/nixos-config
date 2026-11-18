"""scripts/night-quiet.sh, the night-quiet units' decision (modules/core/power-schedule.nix), against a fake
intel_pstate directory: which state each time of day gets for the fleet's night (21:00-08:30, across midnight), on
both sides of each edge, and for a night that does not wrap. Seeded: a missing intel_pstate fails, naming the path; a
night that starts where it ends and a time that is not HH:MM are refused. Nix-free."""
import os
import pathlib
import subprocess
import tempfile

from gate_probe import check, finish

SCRIPT = pathlib.Path(__file__).resolve().parent / "night-quiet.sh"


def run(now, start="21:00", end="08:30", pct="60", sysfs=True, initial=("0", "100")):
    with tempfile.TemporaryDirectory() as t:
        d = pathlib.Path(t) / "intel_pstate"
        if sysfs:
            d.mkdir()
            (d / "no_turbo").write_text(initial[0] + "\n")
            (d / "max_perf_pct").write_text(initial[1] + "\n")
        r = subprocess.run(["bash", str(SCRIPT), start, end, pct], capture_output=True, text=True,
                           env={"PATH": os.environ["PATH"], "QUIET_NOW": now, "QUIET_SYSFS": str(d)})
        state = tuple((d / f).read_text().strip() for f in ("no_turbo", "max_perf_pct")) if sysfs else None
        return r.returncode, state, r.stdout + r.stderr


QUIET, DAY = ("1", "60"), ("0", "100")
# the fleet's night: the edges, a minute either side, and midnight
for now, want in [("20:59", DAY), ("21:00", QUIET), ("21:01", QUIET), ("23:59", QUIET), ("00:00", QUIET),
                  ("00:01", QUIET), ("08:29", QUIET), ("08:30", DAY), ("08:31", DAY), ("12:00", DAY)]:
    # from the opposite state, so the script must write, not just leave a matching value
    rc, state, out = run(now, initial=DAY if want == QUIET else QUIET)
    check(rc == 0 and state == want, f"{now}: {'quiet' if want == QUIET else 'day'} {state} ({out.strip()})")
# a night that does not wrap midnight
for now, want in [("00:59", DAY), ("01:00", QUIET), ("04:59", QUIET), ("05:00", DAY)]:
    rc, state, _ = run(now, start="01:00", end="05:00", initial=DAY if want == QUIET else QUIET)
    check(rc == 0 and state == want, f"01:00-05:00 at {now}: {state}")
rc, state, out = run("22:00", pct="45")
check(rc == 0 and state == ("1", "45"), f"the fleet fact's percentage is what is written ({state})")
rc, _, out = run("22:00", sysfs=False)
check(rc == 1 and "no intel_pstate here" in out, f"seeded: no intel_pstate fails, naming the path ({rc}: {out.strip()})")
rc, _, out = run("22:00", start="21:00", end="21:00")
check(rc == 2 and "starts and ends" in out, f"seeded: a night that starts where it ends is refused ({rc})")
rc, _, out = run("9:00")
check(rc == 2 and "not HH:MM" in out, f"seeded: a time that is not HH:MM is refused ({rc})")
finish()
