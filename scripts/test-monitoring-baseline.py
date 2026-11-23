"""Exercise baseline failure isolation and missing-data behavior without a receiver."""
import contextlib
import importlib.util
import io
import json
import sys
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("baseline", sys.argv.pop(1))
assert spec is not None and spec.loader is not None
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


def response(payload):
    return io.BytesIO(json.dumps(payload).encode())


class BaselineTests(unittest.TestCase):
    def query(self, payload):
        with patch.object(baseline.urllib.request, "urlopen", return_value=response(payload)):
            return baseline.query("http://receiver", "/api/v1/query", "up", "2026-11-20T00:00:00Z")

    def test_empty_remains_empty_and_warnings_survive(self):
        result = self.query({"status": "success", "data": {"result": []}, "warnings": ["partial data"]})
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["result"], [])
        self.assertEqual(result["warnings"], ["partial data"])

    def test_malformed_success_is_error(self):
        for payload in (None, [], {"status": "success"},
                        {"status": "success", "data": {"result": None}},
                        {"status": "success", "data": {"result": {} }},
                        {"status": "success", "data": {"result": []}, "warnings": "bad"}):
            with self.subTest(payload=payload):
                self.assertEqual(self.query(payload)["status"], "error")

    def test_api_error_text_does_not_escape(self):
        result = self.query({"status": "error", "errorType": "https://secret@receiver", "error": "private body"})
        self.assertEqual(result["error"], "api_error")
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(self.query({"status": "error", "errorType": "timeout"})["error"], "timeout")

    def test_transport_error_text_does_not_escape(self):
        with patch.object(baseline.urllib.request, "urlopen", side_effect=urllib.error.URLError("private URL")):
            result = baseline.query("http://receiver", "/api/v1/query", "up", "now")
        self.assertEqual(result["error"], "URLError")
        self.assertNotIn("private", json.dumps(result))

    def test_invalid_json_is_error(self):
        with patch.object(baseline.urllib.request, "urlopen", return_value=io.BytesIO(b"not JSON")):
            result = baseline.query("http://receiver", "/api/v1/query", "up", "now")
        self.assertEqual(result["error"], "JSONDecodeError")

    def test_snapshot_keeps_other_results_and_shared_time_after_error(self):
        requests = []

        def fetch(url, timeout):
            self.assertEqual(timeout, 45)
            requests.append(urllib.parse.urlparse(url))
            if len(requests) == 1:
                return response({"status": "error", "errorType": "timeout"})
            return response({"status": "success", "data": {"result": []}})

        output = io.StringIO()
        with patch.object(sys, "argv", ["snapshot", "--prometheus-url", "http://prom", "--loki-url", "http://loki"]), \
                patch.object(baseline.urllib.request, "urlopen", side_effect=fetch), contextlib.redirect_stdout(output):
            self.assertEqual(baseline.main(), 1)
        snapshot = json.loads(output.getvalue())
        count = len(baseline.PROMETHEUS_QUERIES) + len(baseline.LOKI_QUERIES)
        self.assertEqual(len(snapshot["queries"]), count)
        self.assertEqual(sum(r["status"] == "error" for r in snapshot["queries"].values()), 1)
        self.assertEqual({urllib.parse.parse_qs(r.query)["time"][0] for r in requests}, {snapshot["observed_at"]})
        self.assertEqual({r.path for r in requests}, {"/api/v1/query", "/loki/api/v1/query"})


if __name__ == "__main__":
    unittest.main()
