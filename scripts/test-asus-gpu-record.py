#!/usr/bin/env python3
"""Synthetic GPU recorder checks; never runs a driver or contacts a host."""
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("recorder", sys.argv[1])
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)
sys.argv = [sys.argv[0]]
ROW = "0, GPU-fixture, 125.5, 130, 130, 57, 60, 4200, 8192, Not Active, N/A\n"


class RecorderTests(unittest.TestCase):
    def test_timestamps_unavailable_values_and_cadence(self):
        output = io.StringIO()
        with patch.object(recorder.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, ROW)) as run, \
             patch.object(recorder.time, "monotonic", side_effect=[10, 10.2, 10.3, 11, 11.2]), \
             patch.object(recorder.time, "sleep") as sleep:
            recorder.record(2, output)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["monotonic_started_s"], 10)
        self.assertEqual(rows[0]["monotonic_finished_s"], 10.2)
        self.assertEqual(rows[1]["monotonic_started_s"], 11)
        self.assertEqual(rows[0]["gpus"][0]["power.draw"], "125.5")
        self.assertEqual(rows[0]["gpus"][0][recorder.FIELDS[-1]], "N/A")
        sleep.assert_called_once()
        self.assertAlmostEqual(sleep.call_args.args[0], 0.7)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.kwargs["timeout"], 3)

    def test_invalid_bound_does_not_run_a_query(self):
        with patch.object(recorder.subprocess, "run") as run:
            for samples in [0, -1, 3601]:
                with self.assertRaises(ValueError):
                    recorder.record(samples, io.StringIO())
        run.assert_not_called()

    def test_missing_or_partial_readings_are_not_success(self):
        for text in ["", "0, GPU-fixture\n", ROW + "0\n"]:
            output = io.StringIO()
            with patch.object(recorder.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, text)):
                with self.assertRaises(ValueError):
                    recorder.record(1, output)
            self.assertEqual(output.getvalue(), "")

    def test_query_failure_propagates_without_fabricated_samples(self):
        for error in [subprocess.CalledProcessError(1, "nvidia-smi"), subprocess.TimeoutExpired("nvidia-smi", 3)]:
            output = io.StringIO()
            with patch.object(recorder.subprocess, "run", side_effect=error):
                with self.assertRaises(subprocess.SubprocessError):
                    recorder.record(1, output)
            self.assertEqual(output.getvalue(), "")


unittest.main()
