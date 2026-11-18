"""scripts/wait-metrics.sh, which flake-modules/grafana-dashboards-check.nix waits for its in-sandbox node-exporter with,
on stand-in exporters, without Nix: one that starts late is waited for; with nothing listening, an exporter that answers
without the expected series, or one that has exited, it fails with "exporter did not start" within its bound instead of
leaving a missing or partial scrape for the dashboard check to report as metrics provided by nothing."""
import pathlib
import socket
import subprocess
import tempfile
import time

from gate_probe import check, finish

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "wait-metrics.sh"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def exporter(t, body, delay):
    """A stand-in exporter that starts listening after DELAY seconds and serves BODY at /metrics."""
    port = free_port()
    (t / "metrics").write_text(body)
    code = (f"import http.server, time, functools; time.sleep({delay}); "
            f"h = functools.partial(http.server.SimpleHTTPRequestHandler, directory={str(t)!r}); "
            f"http.server.ThreadingHTTPServer(('127.0.0.1', {port}), h).serve_forever()")
    log = open(t / "exporter.log", "w")
    return port, subprocess.Popen(["python3", "-c", code], stdout=log, stderr=log)


def wait(t, port, pid, seconds, *patterns):
    start = time.monotonic()
    r = subprocess.run(["bash", str(SCRIPT), "node", f"http://127.0.0.1:{port}/metrics", str(t / "node.prom"),
                        str(t / "exporter.log"), str(pid), str(seconds), *patterns], capture_output=True, text=True)
    return r.returncode, r.stderr, time.monotonic() - start


with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    port, p = exporter(t, "node_cpu_seconds_total{cpu=\"0\"} 1\nhomelab_nixos_generation 27\n", 2)
    rc, err, took = wait(t, port, p.pid, 30, "^node_cpu_seconds_total{", "^homelab_nixos_generation 27$")
    p.kill()
    check(rc == 0 and took >= 1.5 and "homelab_nixos_generation 27" in (t / "node.prom").read_text(),
          f"an exporter that starts 2 s late is waited for, and its metrics saved ({rc}, {took:.1f} s, {err.strip()})")

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    (t / "exporter.log").write_text("listen: bind refused\n")
    sleeper = subprocess.Popen(["sleep", "30"])
    rc, err, took = wait(t, free_port(), sleeper.pid, 3, "^node_cpu_seconds_total{")
    sleeper.kill()
    check(rc == 1 and "exporter did not start: node gave no metrics" in err and "bind refused" in err and took < 10
          and not (t / "node.prom").exists(),
          f"seeded: nothing listens: fails within its bound with 'exporter did not start' and the log ({rc}, {took:.1f} s)")

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    port, p = exporter(t, "go_goroutines 7\n", 0)
    rc, err, took = wait(t, port, p.pid, 3, "^node_cpu_seconds_total{")
    p.kill()
    check(rc == 1 and "exporter did not start" in err and "node_cpu_seconds_total" in err and not (t / "node.prom").exists(),
          f"seeded: an exporter answering without the expected series fails, no partial scrape is kept ({rc}, {err.strip()[-120:]})")

with tempfile.TemporaryDirectory() as t:
    t = pathlib.Path(t)
    (t / "exporter.log").write_text("panic: collector failed\n")
    dead = subprocess.Popen(["true"])
    dead.wait()
    rc, err, took = wait(t, free_port(), dead.pid, 30)
    check(rc == 1 and "exited before" in err and "panic: collector failed" in err and took < 5,
          f"seeded: an exporter that has exited fails at once, with its log ({rc}, {took:.1f} s)")

finish()
