import http.server
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request


token = "synthetic-test-token-123456789"
body = b'{"resourceMetrics":[]}'
received = []
received_lock = threading.Lock()


class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(size)
        with received_lock:
            received.append((self.path, dict(self.headers), request_body))
        response = b'{"partialSuccess":{}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_):
        pass


def request_status(url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except urllib.error.URLError:
        return None


def main():
    helper = pathlib.Path(sys.argv[1])
    nginx = sys.argv[2]
    receiver = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    receiver_thread = threading.Thread(target=receiver.serve_forever, daemon=True)
    receiver_thread.start()
    nginx_process = None

    try:
        with tempfile.TemporaryDirectory(prefix="native-otel-relay-test-") as directory:
            root = pathlib.Path(directory)
            credentials = root / "credentials"
            runtime = root / "runtime"
            credentials.mkdir(mode=0o700)
            runtime.mkdir(mode=0o700)
            (credentials / "token").write_text(token + "\n", encoding="utf-8")
            os.chmod(credentials / "token", 0o600)

            environment = os.environ | {
                "CREDENTIALS_DIRECTORY": str(credentials),
                "RUNTIME_DIRECTORY": str(runtime),
            }
            subprocess.run([str(helper)], env=environment, check=True)
            config = runtime / "nginx.conf"
            if config.stat().st_mode & 0o777 != 0o600:
                raise AssertionError("relay config permissions are not 0600")

            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                relay_port = listener.getsockname()[1]

            config_text = config.read_text(encoding="utf-8")
            if "proxy_ssl_verify on;" not in config_text:
                raise AssertionError("relay does not verify the upstream certificate")
            if "proxy_ssl_verify_depth 3;" not in config_text:
                raise AssertionError("relay TLS verification depth is not explicit")
            config_text = config_text.replace(
                "127.0.0.1:4319", f"127.0.0.1:{relay_port}"
            ).replace(
                "https://otlp.sammasak.dev/v1/metrics",
                f"http://127.0.0.1:{receiver.server_port}/v1/metrics",
            )
            config_text = "\n".join(
                line
                for line in config_text.splitlines()
                if "proxy_ssl_" not in line and "proxy_set_header Host" not in line
            ) + "\n"
            config.write_text(config_text, encoding="utf-8")

            subprocess.run(
                [nginx, "-t", "-c", str(config), "-p", f"{runtime}/"],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            nginx_process = subprocess.Popen(
                [nginx, "-c", str(config), "-p", f"{runtime}/"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            endpoint = f"http://127.0.0.1:{relay_port}"
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if request_status(f"{endpoint}/") == 404:
                    break
                time.sleep(0.05)
            else:
                raise AssertionError("local relay did not become ready")

            if request_status(f"{endpoint}/v1/metrics") != 405:
                raise AssertionError("relay accepted a non-POST metrics request")
            if request_status(f"{endpoint}/not-metrics") != 404:
                raise AssertionError("relay accepted a non-metrics path")
            if request_status(
                f"{endpoint}/v1/metrics",
                data=body,
                headers={
                    "Authorization": "Bearer caller-supplied",
                    "Content-Type": "application/json",
                    "X-Sentinel": "must-not-forward",
                },
            ) != 200:
                raise AssertionError("relay did not forward the synthetic metrics body")

            with received_lock:
                forwarded = list(received)
            if len(forwarded) != 1:
                raise AssertionError("relay forwarded requests outside the metrics POST")
            path, headers, forwarded_body = forwarded[0]
            if path != "/v1/metrics" or headers.get("Authorization") != f"Bearer {token}":
                raise AssertionError("relay did not replace authorization with its credential")
            if headers.get("Content-Type") != "application/json":
                raise AssertionError("relay did not preserve the OTLP content type")
            if any(key.lower() == "x-sentinel" for key in headers):
                raise AssertionError("relay forwarded an unrelated caller header")
            if forwarded_body != body:
                raise AssertionError("relay changed the metrics payload")
            print("native OTLP relay: metrics-only route, header filtering, and fake auth passed")
    finally:
        if nginx_process and nginx_process.poll() is None:
            nginx_process.terminate()
            nginx_process.wait(timeout=5)
        receiver.shutdown()
        receiver.server_close()
        receiver_thread.join(timeout=2)


if __name__ == "__main__":
    main()
