"""factum#61: the stop selection_attempts_exhausted carries the widest seed candidate when it holds more than 6
targets, and plan_cli prints its Widest line on stderr for that stop too. Run from the root of a factum tree."""
import pathlib
import re
import sys

driver = pathlib.Path("crates/factum-worker/src/plan/driver.rs").read_text()
cli = pathlib.Path("crates/factum-worker/src/plan_cli.rs").read_text()
report = pathlib.Path("crates/factum-worker/src/plan/report.rs").read_text()
problems = []
variant = re.search(r"SelectionAttemptsExhausted \{(.*?)\n    \},", driver, re.S)
if not variant or not re.search(r"widest:\s*Option<Widest>", variant[1]):
    problems.append("driver.rs: give PlanStop::SelectionAttemptsExhausted a field widest: Option<Widest>")
built = re.search(r"PlanStop::SelectionAttemptsExhausted \{([^}]*)\}\)\)", driver)
if not built or "widest" not in built[1]:
    problems.append("driver.rs: the select stage must set widest when it returns SelectionAttemptsExhausted")
elif not re.search(r"targets\(\)\s*>\s*6|6\s*<\s*\S*targets\(\)", driver):
    problems.append("driver.rs: keep widest only when its targets() is more than 6")
if not re.search(r"SelectionAttemptsExhausted\s*\{[^}]*widest", cli):
    problems.append("plan_cli.rs: print the Widest line on stderr for SelectionAttemptsExhausted as well")
if "SelectionTooWide" not in cli:
    problems.append("plan_cli.rs: keep the Widest line for SelectionTooWide")
if re.search(r"SelectionAttemptsExhausted \{ last \}", report):
    problems.append("report.rs: the match arm must allow the new field (use { last, .. })")
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
