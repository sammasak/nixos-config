"""Exercise the rendered journal filters in real Alloy with synthetic loopback log entries.

Usage: CONFIG ALLOY [ALERT_TOPICS]. With ALERT_TOPICS (comma-separated: a host running ntfy), an ntfy publish line
must reach Loki as a body-free receipt for those topics and not at all for any other, and any other ntfy line naming
message_body (a format the receipt stage does not know) is dropped and counted as ntfy_body_unparsed; without it,
unchanged."""
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

config_path, binary, *topics = sys.argv[1:]
alert_topics = topics[0].split(',') if topics else None
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
cases = [(unit, f'level={level} caller={caller}.go:195 msg="{message}" found={found} test_case={marker}', marker,
          'same' if keep else 'drop') for unit, level, caller, message, found, marker, keep in fixtures]


stamps = {}


def stamp(marker):
    """A time per publish case: a receipt whose title was cut away is known by its time alone."""
    return stamps.setdefault(marker, f'2026-11-27T03:13:{len(stamps):02d}.478+01:00')


def ntfy_publish(topic, marker, cut=False):
    """ntfy 2.30.0's TRACE publish line, as lenovo's journal holds it."""
    body = json.dumps({'id': 'q4O8CUXSpTIW', 'time': 1795745633, 'event': 'message', 'topic': topic,
                       'title': f'[WARNING] "NodeOOMKill" test_case={marker}', 'message': 'BODY-SECRET line\nQuery: q',
                       'priority': 3, 'tags': ['warning', 'orange_circle'], 'click': 'https://CLICK-SECRET'}, indent=2)
    return json.dumps({'time': stamp(marker), 'level': 'TRACE', 'message': 'Received message',
                       'http_method': 'POST', 'http_path': '/', 'message_body': body[:120] if cut else body,
                       'message_body_size': 370, 'message_delayed': False, 'message_id': 'q4O8CUXSpTIW',
                       'tag': 'publish', 'topic': topic, 'visitor_ip': '192.168.10.137'}, separators=(',', ':'))


def receipt(topic, marker, cut=False):
    if alert_topics is None:
        return 'same'
    if topic not in alert_topics:
        return 'drop'
    return {'time': stamp(marker), 'level': 'TRACE', 'message': 'Received message', 'topic': topic,
            'title': None if cut else f'[WARNING] "NodeOOMKill" test_case={marker}',
            'priority': None if cut else 3, 'tags': None if cut else ['warning', 'orange_circle']}


alert = (alert_topics or ['homelab-alerts'])[0]
unparsed = 'same' if alert_topics is None else 'drop'

warn = json.dumps({'time': '2026-11-27T03:20:00+01:00', 'level': 'WARN', 'message': 'Connection closed with error',
                   'error': 'write: broken pipe test_case=ntfy_warn', 'tag': 'subscribe', 'topic': alert,
                   'message_body': 'not a publish'}, separators=(',', ':'))
for topic in (alert_topics or [alert]):
    cases.append(('ntfy-sh.service', ntfy_publish(topic, 'ntfy_alert_' + topic), 'ntfy_alert_' + topic,
                  receipt(topic, 'ntfy_alert_' + topic)))
UNPARSED = ('ntfy_warn', 'ntfy_renamed', 'ntfy_text')
cases += [
    ('ntfy-sh.service', ntfy_publish(alert, 'ntfy_cut', cut=True), 'ntfy_cut', receipt(alert, 'ntfy_cut', cut=True)),
    ('ntfy-sh.service', ntfy_publish('homelab-improvements', 'ntfy_other'), 'ntfy_other',
     receipt('homelab-improvements', 'ntfy_other')),
    ('ntfy-sh.service', warn, 'ntfy_warn', unparsed),
    ('ntfy-sh.service', ntfy_publish(alert, 'ntfy_renamed').replace('"message":"Received message"',
                                                                    '"msg":"Received message"'), 'ntfy_renamed', unparsed),
    ('ntfy-sh.service', '2026/11/27 03:13:53 TRACE Received message (http_method=POST, message_body='
     + json.dumps(json.loads(ntfy_publish(alert, 'ntfy_text'))['message_body']) + f', topic={alert})', 'ntfy_text', unparsed),
    ('ntfy-sh.service', 'Listening on :2586[http], ntfy 2.30.0 test_case=ntfy_start', 'ntfy_start', 'same'),
    ('sshd.service', ntfy_publish(alert, 'unit_publish'), 'unit_publish', 'same'),
]


want_unparsed = None if alert_topics is None else sum(1 for _, _, m, _ in cases if m in UNPARSED)
unparsed_drops = None


def dropped(reason):
    """Alloy's loki_process_dropped_lines_total for reason, None while unreadable."""
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{admin_port}/metrics', timeout=2) as response:
            text = response.read().decode()
    except OSError:
        return None
    return sum(float(m[1]) for m in re.finditer(
        r'^loki_process_dropped_lines_total\{[^}]*reason="%s"[^}]*\} (\S+)$' % reason, text, re.M))


def entries(output):
    """{marker: the entry loki.echo printed} for each case marker in Alloy's output."""
    got = {}
    for m in re.finditer(r'msg="received log entry" .*?entry=("(?:[^"\\]|\\.)*")', output):
        entry = json.loads(m[1])
        mark = re.search(r'test_case=([a-z_-]+)', entry)
        if mark:
            got[mark[1]] = entry
        else:
            try:
                at = json.loads(entry).get('time')
            except (ValueError, AttributeError):
                continue
            got.update({marker: entry for marker, t in stamps.items() if t == at})
    return got
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
        for unit, line, _, _ in cases:
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
            if all(marker in entries(output) for _, _, marker, want in cases if want != 'drop'):
                break
            if proc.poll() is not None:
                raise RuntimeError('Alloy exited before processing fixtures')
            time.sleep(.1)
        while alert_topics is not None and time.monotonic() < deadline:
            unparsed_drops = dropped('ntfy_body_unparsed')
            if unparsed_drops == want_unparsed:
                break
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
            raise RuntimeError(f'Alloy exited with status {proc.returncode}: {output[-4000:]}')
    got = entries(output)
    for unit, line, marker, want in cases:
        if want == 'drop':
            assert marker not in got, (marker, got.get(marker))
        elif want == 'same':
            assert got.get(marker) == line, (marker, got.get(marker), output[-2500:])
        else:
            assert json.loads(got.get(marker) or 'null') == want and 'SECRET' not in got[marker], (marker, got.get(marker))
    assert unparsed_drops == want_unparsed, ('ntfy_body_unparsed drops', unparsed_drops, want_unparsed)
    print('PASS: rendered Alloy pipeline dropped only found=true INFO lookup; creation/error/caller/unit/message cases survived; private units stayed excluded;',
          f'ntfy publish lines cut to receipts for {alert_topics}, other topics dropped, '
          f'{want_unparsed} unknown-format lines naming message_body dropped as ntfy_body_unparsed' if alert_topics else 'ntfy lines unchanged')
