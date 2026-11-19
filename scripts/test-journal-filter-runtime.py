"""Exercise the rendered journal filters in real Alloy with synthetic loopback log entries."""
import json
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

config_path, binary = sys.argv[1:]
raw = pathlib.Path(config_path).read_text()
process = re.search(r'^loki[.]process "drop" \{.*?^\}', raw, re.S | re.M).group(0)
process = process.replace('loki.write.loki.receiver', 'loki.echo.capture.receiver')
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    admin_port = sock.getsockname()[1]
config = process + '\n' + '''loki.source.api "fixture" {
    http {
        listen_address = "127.0.0.1"
        listen_port = %d
    }
    forward_to = [loki.process.drop.receiver]
}
loki.echo "capture" {}
''' % port
fixtures = [
    ('loki.service','info','table_manager','get or create table','true','drop_lookup',False),
    ('loki.service','info','table_manager','get or create table','false','keep_create',True),
    ('loki.service','warn','table_manager','get or create table','true','keep_warn',True),
    ('loki.service','error','table_manager','get or create table','true','keep_error',True),
    ('sshd.service','info','table_manager','get or create table','true','keep_unit',True),
    ('loki.service','info','other','get or create table','true','keep_caller',True),
    ('loki.service','info','table_manager','another message','true','keep_message',True),
    ('authentik.service','info','table_manager','another message','true','drop_private',False),
]
with tempfile.TemporaryDirectory(prefix='alloy-602-') as td:
    path = pathlib.Path(td) / 'config.alloy'
    path.write_text(config)
    subprocess.run([binary, 'validate', str(path)], check=True, capture_output=True)
    capture = pathlib.Path(td) / 'output.log'
    log = capture.open('w')
    proc = subprocess.Popen(
        [binary, 'run', '--disable-reporting', f'--server.http.listen-addr=127.0.0.1:{admin_port}',
         '--storage.path=' + td + '/data', str(path)],
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        streams = []
        for unit, level, caller, message, found, marker, _ in fixtures:
            line = f'level={level} caller={caller}.go:195 msg="{message}" found={found} test_case={marker}'
            streams.append({'stream': {'job': 'host-journal', 'unit': unit},
                            'values': [[str(time.time_ns()), line]]})
        req = urllib.request.Request(
            f'http://127.0.0.1:{port}/loki/api/v1/push',
            data=json.dumps({'streams': streams}).encode(),
            headers={'Content-Type': 'application/json'},
        )
        for i in range(60):
            try:
                with urllib.request.urlopen(req, timeout=2) as response:
                    assert response.status == 204
                break
            except urllib.error.HTTPError:
                raise
            except OSError:
                if proc.poll() is not None:
                    raise RuntimeError('Alloy exited before receiver started')
                time.sleep(.1)
        else:
            raise RuntimeError('receiver did not start')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            output = capture.read_text()
            if all('test_case=' + marker in output for *_, marker, keep in fixtures if keep):
                break
            if proc.poll() is not None:
                raise RuntimeError('Alloy exited before processing fixtures')
            time.sleep(.1)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
            raise
        finally:
            log.close()
        output = capture.read_text()
        if proc.returncode not in (0, -15):
            print(output[-4000:])
    for *_, marker, keep in fixtures:
        assert ('test_case=' + marker in output) == keep, (marker, output[-2500:])
    print('PASS: rendered Alloy pipeline dropped only found=true INFO lookup; creation/error/caller/unit/message cases survived; private units stayed excluded')
