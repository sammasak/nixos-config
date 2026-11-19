#!/usr/bin/env python3
"""Successful completion persists across failures; missing/corrupt records stay unknown."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("backup_metrics", sys.argv[1])
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
# The Nix check consumes this actual collector output as its metric-name catalog.
output_dir = Path(sys.argv[2])
unit_spec = json.loads(Path(sys.argv[3]).read_text())
sys.argv = [sys.argv[0]]


class BackupMetricsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.unit = "authentik-backup"
        self.directory = self.root / self.unit
        self.directory.mkdir()
        self.output = self.root / "backup.prom"
        self.jobs = {self.unit: "archive_list", "llm-gateway-backup": "scratch_restore"}

    def tearDown(self):
        self.tmp.cleanup()

    def successful_record(self, fields=None):
        values = {"ExecMainCode": "1", "ExecMainStatus": "0",
                  "ExecMainStartTimestampMonotonic": "980000000",
                  "ExecMainExitTimestampMonotonic": "990000000"}
        values.update(fields or {})
        result = subprocess.CompletedProcess([], 0, "\n".join(f"{k}={v}" for k, v in values.items()))
        with patch.object(metrics.subprocess, "run", return_value=result) as run, \
                patch.object(metrics.time, "monotonic", return_value=1000), \
                patch.object(metrics.time, "time", return_value=1700):
            metrics.record(self.unit, self.directory)
        self.assertEqual(run.call_args.kwargs["timeout"], 5)

    def test_record_completion_and_duration_not_hook_time(self):
        self.successful_record()
        data = json.loads((self.directory / "success.json").read_text())
        self.assertEqual(data["completed_at"], 1690)
        self.assertEqual(data["duration_seconds"], 10)
        self.assertEqual(stat.S_IMODE((self.directory / "success.json").stat().st_mode), 0o600)

    def test_failed_unfinished_and_killed_runs_preserve_previous_success(self):
        self.successful_record()
        before = (self.directory / "success.json").read_bytes()
        for fields in [{"ExecMainStatus": "1"}, {"ExecMainCode": "2"},
                       {"ExecMainExitTimestampMonotonic": "0"},
                       {"ExecMainExitTimestampMonotonic": "1001000000"}]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.successful_record(fields)
            self.assertEqual((self.directory / "success.json").read_bytes(), before)
        with patch.object(metrics.subprocess, "run", side_effect=subprocess.TimeoutExpired("systemctl", 5)):
            with self.assertRaises(subprocess.TimeoutExpired):
                metrics.record(self.unit, self.directory)
        self.assertEqual((self.directory / "success.json").read_bytes(), before)

    def test_unknown_is_absent_and_unconfigured_state_is_not_exported(self):
        (self.root / "unconfigured").mkdir()
        (self.root / "unconfigured" / "success.json").write_text('SECRET')
        metrics.collect(self.jobs, self.root, self.output)
        text = self.output.read_text()
        self.assertIn('backup="authentik-backup",validation="archive_list"} 0', text)
        self.assertNotIn('homelab_backup_last_success_timestamp_seconds{', text)
        self.assertNotIn('unconfigured', text)
        self.assertNotIn('SECRET', text)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o644)

    def test_corrupt_future_nonfinite_and_wrong_unit_are_unknown(self):
        good = {"version": 1, "unit": self.unit, "completed_at": 1690, "duration_seconds": 10}
        for bad in ['broken', '[]', json.dumps(good | {"unit": "other"}),
                    json.dumps(good | {"completed_at": 2000}), json.dumps(good | {"duration_seconds": -1}),
                    json.dumps(good | {"duration_seconds": float('nan')}),
                    json.dumps(good | {"completed_at": True}),
                    json.dumps(good | {"completed_at": 10**400}),
                    json.dumps(good | {"duration_seconds": 10**400})]:
            with self.subTest(bad=bad), patch.object(metrics.time, "time", return_value=1700):
                (self.directory / "success.json").write_text(bad)
                metrics.collect(self.jobs, self.root, self.output)
                self.assertNotIn('homelab_backup_last_success_timestamp_seconds{', self.output.read_text())

    def test_bad_job_does_not_hide_another_jobs_success(self):
        (self.directory / "success.json").write_text(json.dumps({
            "version": 1, "unit": self.unit, "completed_at": 10**400, "duration_seconds": 1}))
        other = self.root / "llm-gateway-backup"
        other.mkdir()
        (other / "success.json").write_text(json.dumps({
            "version": 1, "unit": "llm-gateway-backup", "completed_at": 1690, "duration_seconds": 3}))
        with patch.object(metrics.time, "time", return_value=1700):
            metrics.collect(self.jobs, self.root, self.output)
        text = self.output.read_text()
        self.assertIn('homelab_backup_metadata_available{backup="authentik-backup",validation="archive_list"} 0', text)
        self.assertIn('homelab_backup_last_success_timestamp_seconds{backup="llm-gateway-backup",validation="scratch_restore"} 1690', text)

    def test_symlink_fifo_and_oversized_files_are_not_read(self):
        path = self.directory / "success.json"
        secret = self.root / "secret"
        secret.write_text("SECRET")
        path.symlink_to(secret)
        metrics.collect(self.jobs, self.root, self.output)
        self.assertNotIn('homelab_backup_last_success_timestamp_seconds{', self.output.read_text())
        path.unlink()
        os.mkfifo(path)
        metrics.collect(self.jobs, self.root, self.output)
        self.assertNotIn('homelab_backup_last_success_timestamp_seconds{', self.output.read_text())
        path.unlink()
        path.write_text(' ' * 4097)
        metrics.collect(self.jobs, self.root, self.output)
        self.assertNotIn('homelab_backup_last_success_timestamp_seconds{', self.output.read_text())

    def test_collection_preserves_old_success_and_writes_catalog(self):
        self.successful_record()
        with patch.object(metrics.time, "time", return_value=999999):
            metrics.collect(self.jobs, self.root, self.output)
        text = self.output.read_text()
        self.assertIn('homelab_backup_last_success_timestamp_seconds{backup="authentik-backup",validation="archive_list"} 1690.0', text)
        self.assertIn('homelab_backup_last_success_duration_seconds{backup="authentik-backup",validation="archive_list"} 10.0', text)
        self.assertIn('homelab_backup_collector_last_success_timestamp_seconds 999999', text)
        self.assertEqual(list(self.root.glob('tmp*')), [])
        output_dir.mkdir(exist_ok=True)
        (output_dir / "backup.prom").write_text(text)

    def test_invalid_labels_rejected_before_export(self):
        for jobs in [{'bad"label': "archive_list"}, {self.unit: "invented"}]:
            with self.assertRaises(ValueError):
                metrics.collect(jobs, self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_evaluated_unit_wiring_keeps_identity_state_and_nonblocking_hook(self):
        expected = {"authentik-backup": ("postgres", None),
                    "authentik-offhost": ("root", None),
                    "llm-gateway-backup": ("llm-gateway", "llm-gateway-backup"),
                    "open-webui-backup": ("root", "open-webui-backup")}
        self.assertEqual(set(unit_spec["units"]), set(expected))
        for unit, (user, original_state) in expected.items():
            service = unit_spec["units"][unit]
            self.assertEqual(service.get("User", "root"), user)
            self.assertIn("backup-metrics/" + unit, service["StateDirectory"])
            if original_state:
                self.assertIn(original_state, service["StateDirectory"])
            self.assertEqual(service["StateDirectoryMode"], "0700")
            hooks = service["ExecStartPost"]
            self.assertEqual(len(hooks), 1)
            self.assertRegex(hooks[0], r'^-/nix/store/.+/bin/timeout --kill-after=2s 10s ')
            self.assertTrue(hooks[0].endswith(f' record {unit} /var/lib/backup-metrics/{unit}'))
        for host, collector in unit_spec["collectors"].items():
            self.assertEqual(collector["ProtectSystem"], "strict", host)
            self.assertEqual(collector["ReadWritePaths"], ["/run/node-exporter-textfile"])
            self.assertEqual(collector["User"], "root")


unittest.main()
