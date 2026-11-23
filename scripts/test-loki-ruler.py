"""Loki's ruler as black-pi renders it (homelab.loki.ruler), on loopback: synthetic compaction events and systemd OOM
lines pushed to Loki must reach a real Prometheus by remote write as the per-host, per-worker recording and a stub
Alertmanager as UnitOOMKilled, with no other label. The rules are evaluated as Loki parses them, not imitated.
Usage: test-loki-ruler.py LOKI PROMETHEUS CONFIG_JSON WORKDIR"""
import http.server
import json
import pathlib
import subprocess
import sys
import threading
import time
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
    now = time.time_ns()

    def compaction(at, **attributes):
        return [str(now - at), json.dumps({'body': 'compaction', 'attributes': {'session.id': f's{at}', **attributes}})]

    # the stream labels and line shape scripts/test-alloy-otlp-log-loki.py holds alloy-otlp to
    harness = {'event_name': 'compaction', 'exporter': 'OTLP', 'host_name': 'acer-swift', 'job': 'claude-code',
               'level': 'INFO', 'observer': 'harness', 'service_name': 'claude-code'}
    journal = {'job': 'host-journal', 'host': 'msi-ms7758', 'unit': 'init.scope'}
    streams = [
        {'stream': harness, 'values': [
            compaction(5000, worker='herman', trigger='auto', pre_tokens='300000', post_tokens='20000'),
            compaction(4000, worker='herman', trigger='auto'),
            compaction(3000, worker='a1', trigger='auto'),
            compaction(2000, worker='a1', trigger='manual'),
            compaction(1000, trigger='auto'),
        ]},
        {'stream': journal, 'values': [
            [str(now - 3000), 'nav-metrics.service: A process of this unit has been killed by the OOM killer.'],
            [str(now - 2000), "nav-metrics.service: Failed with result 'oom-kill'."],
            [str(now - 1000), 'run-u123.service: A process of this unit has been killed by the OOM killer.'],
        ]},
    ]
    urllib.request.urlopen(urllib.request.Request(
        f'http://127.0.0.1:{LOKI}/loki/api/v1/push', data=json.dumps({'streams': streams}).encode(),
        headers={'Content-Type': 'application/json'}), timeout=10)

    query = urllib.parse.urlencode({'query': 'max_over_time(host_worker:claude_code_auto_compactions:count1m[10m])'})
    want_recorded = {(('host', 'acer-swift'), ('worker', 'herman')): '2', (('host', 'acer-swift'), ('worker', 'a1')): '1',
                     (('host', 'acer-swift'),): '1'}
    want_alerts = {'nav-metrics.service', 'transient'}
    recorded, fired = {}, set()
    deadline = time.time() + 300
    while time.time() < deadline and (recorded != want_recorded or fired != want_alerts):
        time.sleep(10)
        result = json.loads(get(f'http://127.0.0.1:{PROM}/api/v1/query?{query}'))['data']['result']
        recorded = {tuple(sorted(s['metric'].items())): s['value'][1] for s in result}
        for a in alerts:
            assert a['labels'] == {'alertname': 'UnitOOMKilled', 'node': 'msi-ms7758', 'oom_unit': a['labels'].get('oom_unit'),
                                   'severity': 'warning', 'team': 'homelab'}, a['labels']
            fired.add(a['labels']['oom_unit'])
    assert recorded == want_recorded, f'recorded {recorded}, want {want_recorded}'
    assert fired == want_alerts, f'fired {fired}, want {want_alerts}'
    print('PASS: the ruler remote-writes auto compactions per host and worker and sends UnitOOMKilled per unit',
          flush=True)
except BaseException:
    sys.stderr.write((root / 'loki.log').read_text()[-4000:])
    raise
finally:
    for process in processes:
        process.terminate()
