"""lenovo's ollama-portforward supervisor restarts a wedged forward (nixos-config#84).

The fake forward serves HTTP, then wedges like kubectl after its pod is gone:
still running and listening, but every connection closes without a reply.
"""
import os
import socket
import subprocess
import sys
import tempfile
import time

import gate_probe

FAKE = r'''
import socket, sys, time
port, mode, alive_for = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(16); s.settimeout(0.2)
start = time.time()
while True:
    if mode == "exit" and time.time() - start > alive_for:
        sys.exit(0)
    try:
        c, _ = s.accept()
    except socket.timeout:
        continue
    if mode == "wedge" and time.time() - start > alive_for:
        c.close()
        continue
    c.recv(4096)
    status = b"500 Internal Server Error" if mode == "error" else b"200 OK"
    c.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    c.close()
'''

failed = 0


def check(ok, what):
    global failed
    print(("PASS: " if ok else "FAIL: ") + what)
    failed += not ok


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


P = gate_probe.section("ollama-portforward")
exe, unit = P["exe"], P["unit"]
argv = unit["ExecStart"].split()
check(argv[0] == exe and argv[1] == "http://127.0.0.1:8080/api/tags" and argv[2].endswith("/bin/kubectl")
      and argv[3:6] == ["port-forward", "--address", "127.0.0.1"] and "deploy/llm-gateway" in argv
      and "8080:11434" in argv and unit.get("Restart") == "always",
      f"the unit runs kubectl under the supervisor, probing the forwarded port ({unit['ExecStart']})")

tmp = tempfile.mkdtemp()
fake = os.path.join(tmp, "fake_forward.py")
with open(fake, "w") as f:
    f.write(FAKE)
env = dict(os.environ, PROBE_INTERVAL="0.3", PROBE_FAILURES="3")


def start(mode, alive_for, supervised=True):
    port = free_port()
    cmd = [sys.executable, fake, str(port), mode, str(alive_for)]
    if supervised:
        cmd = [exe, f"http://127.0.0.1:{port}/api/tags", *cmd]
    return subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def fake_running():
    return subprocess.run(["pgrep", "-f", fake], capture_output=True).returncode == 0


# without the supervisor (the unit before #84), the wedged forward never exits, so Restart= never fires
bare = start("wedge", 1.0, supervised=False)
time.sleep(4)
check(bare.poll() is None, "control: a wedged forward on its own keeps running (the reported bug)")
bare.kill(); bare.wait()

p = start("wedge", 1.0)
try:
    rc = p.wait(timeout=10)
    err = p.stderr.read()
except subprocess.TimeoutExpired:
    p.kill(); rc, err = None, "still running after 10s"
time.sleep(0.5)
check(rc == 1 and "no response 3 times" in err and not fake_running(),
      f"a wedged forward: the supervisor exits 1 and takes the forward down ({rc}, {err.strip()})")

p = start("error", 0)
time.sleep(3)
check(p.poll() is None, "a forward answering HTTP 500 is alive: Ollama errors do not restart it")
p.terminate(); p.wait(timeout=5)

p = start("exit", 1.0)
try:
    rc = p.wait(timeout=5)
except subprocess.TimeoutExpired:
    p.kill(); rc = None
check(rc is not None and rc != 0, f"a forward that exits 0 still ends the supervisor non-zero ({rc})")

subprocess.run(["pkill", "-f", fake])
sys.exit(1 if failed else 0)
