"""A switch can neither kill the agent sessions on a host nor wait forever on a unit: Herdr's user server is kept
across a switch on every host that runs it (a restart ends every pane and agent).

Evaluation only: unit declarations, never a build or a switch."""
import sys

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


s = gate_probe.section("switch-safety")

herdr = {h: u for h, u in s["herdr"].items() if u is not None}
check({"lenovo", "acer-swift", "msi-ms7758"} <= herdr.keys(), f"the agent hosts run a Herdr server ({sorted(herdr)})")
for host, unit in sorted(herdr.items()):
    check(unit["X-SwitchMethod"] == "keep-old", f"{host}: a switch keeps the running Herdr server ({unit})")

sys.exit(1 if failed else 0)
