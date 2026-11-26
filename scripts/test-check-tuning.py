"""scripts/check-tuning.py on an inline fixture of gate-step records, without Nix or Loki: a pass, a fail, a record
without seconds, a malformed seconds, two gates and a spool line; the rows and the skipped count, and that the
malformed record is not read as 0 seconds (it would lower the mean and add a run)."""
import pathlib
import subprocess
import sys
import tempfile

from gate_probe import check, finish

SCRIPT = pathlib.Path(__file__).resolve().parent / "check-tuning.py"

FIXTURE = """\
gate=nixos-qa-push step=nixos-push-eval seconds=120 result=pass sha=aaaa
gate=nixos-qa-push step=nixos-push-eval seconds=240 result=fail sha=bbbb
gate=nixos-qa-push step=nixos-push-eval seconds=abc result=pass sha=cccc
gate-step gate=pool-merge-check step=pool-merge-eval check=lenovo seconds=30 result=pass sha=dddd head=eeee
gate=pool-merge-check step=pool-merge-eval check=lenovo result=pass sha=ffff
not a record at all

"""


def run(text: str) -> tuple[int, list[str]]:
    with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
        f.write(text)
        f.flush()
        r = subprocess.run([sys.executable, str(SCRIPT), "--records", f.name], capture_output=True, text=True,
                           check=False)
    return r.returncode, r.stdout.splitlines()


code, out = run(FIXTURE)
check(code == 0, f"exit 0 on the fixture ({code})")
rows = [line for line in out if line.startswith("| ") and not line.startswith("| gate ")]
check(rows == ["| nixos-qa-push | nixos-push-eval | - | 2 | 3.0 | 4.0 | 1 |",
               "| pool-merge-check | pool-merge-eval | lenovo | 1 | 0.5 | 0.5 | 0 |"],
      f"one row per gate, step and check, with runs, mean and worst minutes and fails ({rows})")
check("3 records read, 3 skipped (no step, or no whole seconds)" in out,
      f"the record without seconds, the malformed seconds and the non-record are skipped and counted ({out[-1:]})")
check("| nixos-qa-push | nixos-push-eval | - | 3 | 2.0 | 4.0 | 1 |" not in out,
      "seconds=abc is not read as 0 seconds (3 runs, mean 2.0)")

code, out = run("gate=x step=y seconds= result=pass\n\n")
check(code == 2 and "0 records read, 1 skipped (no step, or no whole seconds)" in out,
      f"only unreadable records: exit 2, nothing folded in ({code}, {out[-1:]})")

finish()
