"""Run the real loopback collector against controlled exposition and transport failures."""
import http.server
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

HELPER = Path(sys.argv.pop(1)).resolve()
CATALOG = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None
SPEC = json.loads(Path(sys.argv.pop(1)).read_text()) if len(sys.argv) > 1 else None
FIXTURE = '''loki_source_journal_target_lines_total{component_id="loki.source.journal.host",component_path="/"} 1.5e3
loki_write_sent_entries_total{component_id="loki.write.loki",host="private-host",tenant=""} 1200
loki_write_batch_retries_total{component_id="loki.write.loki",host="private-host"} 2
loki_write_dropped_entries_total{component_id="loki.write.loki",host="private-host",reason="rate_limited"} 3
loki_process_dropped_lines_total{component_id="loki.process.drop",reason="private_unit"} 297
'''


class Handler(http.server.BaseHTTPRequestHandler):
    body = FIXTURE.encode()
    code = 200

    def do_GET(self):
        self.send_response(self.code)
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *_args):
        pass


class CollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.output = self.directory / 'journal.prom'

    def collect(self, body=FIXTURE, code=200):
        Handler.body, Handler.code = body.encode(), code
        result = subprocess.run(
            ['bash', str(HELPER), str(self.directory), f'http://127.0.0.1:{self.server.server_port}/metrics'],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, 'LC_ALL': 'C'})
        text = self.output.read_text()
        self.assertEqual(list(self.directory.iterdir()), [self.output])
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o644)
        return result, text

    def test_counters_separate_losses_from_filtering_and_remove_identity(self):
        result, text = self.collect()
        self.assertEqual(result.returncode, 0, result.stderr)
        for sample in ['homelab_journal_reader_lines_total 1500',
                       'homelab_journal_writer_sent_entries_total 1200',
                       'homelab_journal_writer_retries_total 2',
                       'homelab_journal_writer_dropped_entries_total{reason="rate_limited"} 3',
                       'homelab_journal_filtered_lines_total{reason="private_unit"} 297',
                       'homelab_journal_metrics_collection_success 1']:
            self.assertIn(sample, text)
        for private in ['private-host', 'component_id', 'tenant', 'component_path']:
            self.assertNotIn(private, text)
        if CATALOG is not None:
            CATALOG.mkdir(parents=True, exist_ok=True)
            (CATALOG / 'journal.prom').write_text(text)

    def test_schema_failures_replace_previous_counters_with_failure(self):
        for body in [FIXTURE.replace(' 1200', ' NaN'), FIXTURE.replace(' 1200', ' -1'),
                     FIXTURE.replace(' 1200', ' 1e999'), FIXTURE + FIXTURE.splitlines()[0] + '\n',
                     'garbage', FIXTURE.replace('loki.source.journal.host', 'unexpected'),
                     FIXTURE.replace('reason="rate_limited"', 'reason="private user text"')]:
            with self.subTest(body=body):
                self.collect()
                result, text = self.collect(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('homelab_journal_metrics_collection_success 0', text)
                self.assertNotIn('_total', text)
                self.assertNotIn('private user text', result.stderr)

    def test_transport_failure_and_oversized_response_are_not_zero_losses(self):
        for body, code in [('private response body', 503), (FIXTURE + '#' * 262144, 200)]:
            with self.subTest(code=code):
                result, text = self.collect(body, code)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('_total', text)
                self.assertNotIn('private response body', result.stderr)

    def test_future_reasons_are_bounded_and_aggregated(self):
        extra = '\n'.join(
            f'loki_write_dropped_entries_total{{reason="{r}",component_id="loki.write.loki"}} {v}'
            for r, v in [('new_reason', 4), ('another_reason', 5)])
        result, text = self.collect(FIXTURE + extra + '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('homelab_journal_writer_dropped_entries_total{reason="other"} 9', text)
        self.assertNotIn('new_reason', text)

    def test_unrelated_components_and_optional_filters_do_not_invent_series(self):
        body = '\n'.join(line for line in FIXTURE.splitlines() if not line.startswith('loki_process'))
        body += '\nloki_write_sent_entries_total{component_id="other"} 999\n'
        result, text = self.collect(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('homelab_journal_writer_sent_entries_total 1200', text)
        self.assertNotIn('homelab_journal_filtered_lines_total{', text)

    @unittest.skipIf(SPEC is None, 'evaluated units supplied by Nix check')
    def test_evaluated_units_preserve_loopback_and_resource_boundaries(self):
        self.assertEqual(len(SPEC), 5)
        for host, facts in SPEC.items():
            with self.subTest(host=host):
                unit = facts['service']
                self.assertIn('--server.http.listen-addr=127.0.0.1:12345', facts['flags'])
                self.assertIn('--collector.textfile.directory=/run/journal-metrics', facts['nodeFlags'])
                self.assertIn('http://127.0.0.1:12345/metrics', unit['ExecStart'])
                self.assertIn('alloy.service', facts['after'])
                self.assertIn('alloy.service', facts['wants'])
                self.assertEqual(unit['MemoryMax'], '16M')
                self.assertEqual(unit['MemorySwapMax'], 0)
                self.assertFalse(unit['DynamicUser'])
                self.assertEqual(unit['User'], 'journal-metrics')
                self.assertEqual(unit['Group'], 'journal-metrics')
                self.assertEqual(unit['RuntimeDirectory'], 'journal-metrics')
                self.assertEqual(unit['RuntimeDirectoryMode'], '0755')
                self.assertEqual(unit['RuntimeDirectoryPreserve'], 'yes')
                self.assertEqual(unit['IPAddressDeny'], 'any')
                self.assertEqual(unit['IPAddressAllow'], 'localhost')
                self.assertIn('timers.target', facts['wantedBy'])
                self.assertEqual(facts['timer']['OnUnitActiveSec'], '1min')


if __name__ == '__main__':
    unittest.main()
