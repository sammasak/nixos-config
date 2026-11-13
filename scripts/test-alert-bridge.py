"""homelab.alertBridge (modules/homelab/alert-bridge.nix): lenovo alone runs the bridge, as a throwaway user with
no capabilities, publishing to the native ntfy on loopback; its port is accepted from the LAN and the pod network
only; the unit's binary is built and answers /health on the address the unit's start probe asks."""
import os
import socket
import subprocess
import sys
import time
import urllib.request

import gate_probe

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


P = gate_probe.section("alert-bridge")
env, unit = P["environment"], P["serviceConfig"]

running = sorted(name for name, has in P["units"].items() if has)
check(running == ["lenovo"], f"lenovo alone runs alert-bridge {running}")
check(env["ALERT_BRIDGE_NTFY_URL"] == f"http://127.0.0.1{P['ntfyListen']}/homelab-alerts-shadow",
      f"it publishes to the native ntfy on loopback, to the shadow topic until cutover ({env['ALERT_BRIDGE_NTFY_URL']})")
check(unit["DynamicUser"] is True and unit["CapabilityBoundingSet"] == "" and unit["ProtectSystem"] == "strict",
      "it runs as a throwaway user with no capabilities and a read-only system")

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
listen_port = env["ALERT_BRIDGE_LISTEN"].rsplit(":", 1)[1]
health = unit["ExecStartPost"].split()[-1]
check(health == f"http://127.0.0.1:{listen_port}/health", f"the start probe asks the port the bridge listens on ({health})")

accepted = sorted(rule.split()[rule.split().index("-s") + 1] for rule in P["firewall"]["rules"].splitlines()
                  if f"--dport {listen_port} " in rule)
check(int(listen_port) not in P["firewall"]["open"] and accepted == sorted([P["lanCidr"], "10.42.0.0/16"]),
      f"the port is accepted from the LAN and the pod network only {accepted}")

bridge = subprocess.Popen([unit["ExecStart"]], env={**env, "ALERT_BRIDGE_LISTEN": f"127.0.0.1:{port}"})
try:
    answer = None
    for _ in range(50):
        if bridge.poll() is not None:
            break
        try:
            answer = urllib.request.urlopen(health.replace(f":{listen_port}/", f":{port}/"), timeout=2).status
            break
        except OSError:
            time.sleep(0.1)
    check(answer == 200, f"the unit's binary starts with the unit's settings and answers /health ({answer})")
finally:
    bridge.kill()
    bridge.wait()

sys.exit(1 if failed else 0)
