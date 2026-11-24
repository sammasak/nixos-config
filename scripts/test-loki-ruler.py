"""Loki's ruler as black-pi renders it (homelab.loki.ruler), on loopback: synthetic compaction events and systemd OOM
lines pushed to Loki must reach a real Prometheus by remote write as the per-host, per-worker recording and a stub
Alertmanager as UnitOOMKilled, with no other label, whose query annotation runs on that Loki. The rules are evaluated
as Loki parses them, not imitated.
Usage: test-loki-ruler.py LOKI PROMETHEUS CONFIG_JSON WORKDIR"""
import http.server
import json
import pathlib
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

loki_bin, prom_bin, config, work = sys.argv[1:5]
root = pathlib.Path(work)
LOKI, PROM, AM = 13100, 19090, 19093

c = json.load(open(config))
data = c['common']['path_prefix']
c = json.loads(json.dumps(c).replace(data, str(root / 'loki')))
c['server'].update(http_listen_address='127.0.0.1', http_listen_port=LOKI)
c['ruler']['alertmanager_url'] = f'http://127.0.0.1:{AM}'
c['ruler']['remote_write']['clients']['prometheus']['url'] = f'http://127.0.0.1:{PROM}/api/v1/write'
(root / 'loki.json').write_text(json.dumps(c))
(root / 'prometheus.yml').write_text('global: {}\n')

alerts = []


class Alertmanager(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        alerts.extend(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


threading.Thread(target=http.server.HTTPServer(('127.0.0.1', AM), Alertmanager).serve_forever, daemon=True).start()


def get(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return response.read().decode()


processes = [
    subprocess.Popen([prom_bin, f'--config.file={root}/prometheus.yml', f'--storage.tsdb.path={root}/prometheus',
                      f'--web.listen-address=127.0.0.1:{PROM}', '--web.enable-remote-write-receiver'],
                     stderr=open(root / 'prometheus.log', 'w')),
    subprocess.Popen([loki_bin, f'-config.file={root}/loki.json'], stderr=open(root / 'loki.log', 'w')),
]
try:
    for _ in range(90):
        try:
            if get(f'http://127.0.0.1:{LOKI}/ready').strip() == 'ready':
                break
        except OSError:
            pass
        time.sleep(2)
    else:
        raise SystemExit('Loki not ready after 180 s')

    def push(streams):
        urllib.request.urlopen(urllib.request.Request(
            f'http://127.0.0.1:{LOKI}/loki/api/v1/push', data=json.dumps({'streams': streams}).encode(),
            headers={'Content-Type': 'application/json'}), timeout=10)

    def compactions(host, events):
        now = time.time_ns()
        # the stream labels and line shape scripts/test-alloy-otlp-log-loki.py holds alloy-otlp to
        stream = {'event_name': 'compaction', 'exporter': 'OTLP', 'host_name': host, 'job': 'claude-code',
                  'level': 'INFO', 'observer': 'harness', 'service_name': 'claude-code'}
        return {'stream': stream, 'values': [
            [str(now - 1000 * (len(events) - i)),
             json.dumps({'body': 'compaction', 'attributes': {'session.id': f's{i}', **a}})]
            for i, a in enumerate(events)]}

    def journal(unit, lines):
        now = time.time_ns()
        return {'stream': {'job': 'host-journal', 'host': 'msi-ms7758', 'unit': unit},
                'values': [[str(now - 1000 * (len(lines) - i)), line] for i, line in enumerate(lines)]}

    oom = 'A process of this unit has been killed by the OOM killer.'
    push([
        compactions('acer-swift', [
            dict(worker='herman', trigger='auto', pre_tokens='300000', post_tokens='20000'),
            dict(worker='herman', trigger='auto'),
            dict(worker='a1', trigger='auto'),
            dict(worker='a1', trigger='manual'),
            dict(worker='a1'),
            dict(trigger='auto'),
        ]),
        compactions('lenovo-21cb001pmx', [dict(worker='w2', trigger='auto')]),
        journal('init.scope', [f'nav-metrics.service: {oom}', "nav-metrics.service: Failed with result 'oom-kill'.",
                               f'run-u123.service: {oom}', f'session-3.scope: {oom}']),
        # a unit's own line quoting the text is no OOM kill
        journal('quoting.service', [f'quoted.service: {oom}']),
        # what UnitOOMKilled's query annotation names besides init.scope: the unit's own stream
        journal('nav-metrics.service', ['fatal error: runtime: out of memory']),
    ])
    # a second batch a minute boundary later: counted once, in its own window
    time.sleep(75)
    push([compactions('acer-swift', [dict(worker='herman', trigger='auto')])])

    query = urllib.parse.urlencode({'query': 'sum_over_time(host_worker:claude_code_auto_compactions:count1m[15m])'})
    want_recorded = {(('host', 'acer-swift'), ('worker', 'herman')): '3', (('host', 'acer-swift'), ('worker', 'a1')): '1',
                     (('host', 'acer-swift'),): '1', (('host', 'lenovo-21cb001pmx'), ('worker', 'w2')): '1'}
    want_alerts = {'nav-metrics.service', 'transient', 'session'}

    def read():
        result = json.loads(get(f'http://127.0.0.1:{PROM}/api/v1/query?{query}'))['data']['result']
        fired = set()
        for a in alerts:
            assert a['labels'] == {'alertname': 'UnitOOMKilled', 'node': 'msi-ms7758', 'oom_unit': a['labels'].get('oom_unit'),
                                   'severity': 'warning', 'team': 'homelab'}, a['labels']
            assert 'OOM event(s) in' in a['annotations']['description'], a['annotations']
            fired.add(a['labels']['oom_unit'])
        return {tuple(sorted(s['metric'].items())): s['value'][1] for s in result}, fired

    recorded, fired = read()
    deadline = time.time() + 300
    while time.time() < deadline and (recorded != want_recorded or fired != want_alerts):
        time.sleep(10)
        recorded, fired = read()
    assert recorded == want_recorded, f'recorded {recorded}, want {want_recorded}'
    assert fired == want_alerts, f'fired {fired}, want {want_alerts}'
    # past every window that could still hold the lines: an overlapping or repeated count shows here
    time.sleep(150)
    recorded, fired = read()
    assert recorded == want_recorded, f'later recorded {recorded}, want {want_recorded}'
    assert fired == want_alerts, f'later fired {fired}, want {want_alerts}'
    # each alert's query annotation as the ruler rendered it is LogQL this Loki runs (a parse error is a 400) and finds
    # the OOM lines with; an unfolded unit's own stream among them, so a misrendered oom_unit shows
    for unit, q in {(a['labels']['oom_unit'], a['annotations']['query']) for a in alerts}:
        try:
            found = json.loads(get(f"http://127.0.0.1:{LOKI}/loki/api/v1/query_range?{urllib.parse.urlencode({'query': q})}"))
        except urllib.error.HTTPError as e:
            raise SystemExit(f'the query annotation {q!r} does not run: {e.read().decode()}')
        streams = {r['stream']['unit']: [v[1] for v in r['values']] for r in found['data']['result']}
        assert any(oom in l for l in streams.get('init.scope', [])), f'the query annotation {q!r} finds no OOM line ({streams})'
        assert unit in ('transient', 'session') or unit in streams, f"the query annotation {q!r} misses {unit}'s stream ({streams})"
    print('PASS: the ruler remote-writes auto compactions once per host and worker and sends UnitOOMKilled per unit, '
          'whose query annotation runs', flush=True)
except BaseException:
    sys.stderr.write((root / 'loki.log').read_text()[-4000:])
    raise
finally:
    for process in processes:
        process.terminate()
