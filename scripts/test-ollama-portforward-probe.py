import http.server
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import time


class Tags(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        status = 200 if self.path == "/api/tags" else 404
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def parse_unit(path):
    env, service = {}, {}
    for line in pathlib.Path(path).read_text().splitlines():
        if line.startswith('Environment="'):
            key, _, value = line[len('Environment="'):-1].partition("=")
            env[key] = value
        elif "=" in line and not line.startswith("["):
            key, _, value = line.partition("=")
            service[key] = value
    return env, service


def check(condition, message):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)
    print(f"PASS: {message}")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_exit(process, seconds):
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        return None


def main():
    env, service = parse_unit(sys.argv[1])
    exec_start = service["ExecStart"].split()
    wrapper = exec_start[0]

    check(exec_start[0].endswith("/bin/probed-forward"), "ExecStart runs the probe wrapper")
    check(exec_start[1].endswith("/bin/kubectl") and exec_start[2] == "port-forward",
          "the wrapper supervises kubectl port-forward")
    check(service.get("Restart") == "always", "systemd restarts the unit when the wrapper exits")
    check(env.get("PROBE_URL") == "http://127.0.0.1:8080/api/tags", "probe targets the forwarded port")
    check(int(env["PROBE_FAILURES"]) >= 2, "one failed probe does not restart the forward")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Tags)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fast = {
        **os.environ,
        "PROBE_URL": f"http://127.0.0.1:{server.server_port}/api/tags",
        "PROBE_INTERVAL": "0.2",
        "PROBE_FAILURES": "3",
    }

    with tempfile.TemporaryDirectory(prefix="probed-forward-test-") as directory:
        pid_file = pathlib.Path(directory) / "child.pid"
        child = ["sh", "-c", f'echo $$ > {pid_file}; exec sleep 60']
        process = subprocess.Popen([wrapper, *child], env=fast)
        check(wait_exit(process, 2) is None, "a healthy forward keeps running")
        child_pid = int(pid_file.read_text())

        server.shutdown()
        server.server_close()
        status = wait_exit(process, 5)
        check(status == 1, "a forward that stops answering exits non-zero")
        time.sleep(0.2)
        check(not alive(child_pid), "the wedged kubectl is killed with it")

    process = subprocess.Popen([wrapper, "sh", "-c", "exit 7"], env=fast)
    check(wait_exit(process, 5) == 7, "kubectl exiting on its own still ends the unit with its status")


main()
