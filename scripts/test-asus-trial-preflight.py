#!/usr/bin/env python3
"""The owner time boundary must run before any subprocess or host connection."""

import argparse
from contextlib import redirect_stderr
from datetime import datetime, timedelta, timezone
from io import StringIO
import importlib.util
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preflight", sys.argv[1])
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)
sys.argv = [sys.argv[0]]


class PreflightTests(unittest.TestCase):
    boundary = datetime(2026, 11, 21, 8, tzinfo=timezone.utc)

    def test_before_boundary_never_invokes_subprocess(self):
        with patch.object(preflight.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                preflight.collect(
                    self.boundary - timedelta(microseconds=1), self.boundary
                )
        run.assert_not_called()

    def test_boundary_is_0900_cet_and_uses_one_bounded_readonly_connection(self):
        self.assertEqual(
            preflight.parse_not_before("2026-11-21T09:00:00+01:00"), self.boundary
        )
        with patch.object(preflight.subprocess, "run") as run:
            preflight.collect(self.boundary, self.boundary)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertEqual(
            command[-2:], ["asus-b460m", "/run/current-system/sw/bin/bash -s"]
        )
        self.assertEqual(run.call_args.kwargs["timeout"], 30)
        self.assertTrue(run.call_args.kwargs["check"])
        # Protect the evidence collector against acquiring a wake/start/build side effect.
        for forbidden in [
            "wakeonlan",
            "systemctl start",
            "systemctl restart",
            "nix build",
            "api/generate",
            "api/chat",
        ]:
            self.assertNotIn(forbidden, run.call_args.kwargs["input"])

    def test_connection_failure_is_not_reported_as_success(self):
        with patch.object(
            preflight.subprocess,
            "run",
            side_effect=subprocess.CalledProcessError(255, "ssh"),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                preflight.collect(self.boundary + timedelta(minutes=1), self.boundary)

    def test_missing_boundary_never_invokes_subprocess(self):
        with patch.object(sys, "argv", ["preflight"]), redirect_stderr(StringIO()):
            with patch.object(preflight.subprocess, "run") as run:
                with self.assertRaises(SystemExit) as result:
                    preflight.main()
        self.assertEqual(result.exception.code, 2)
        run.assert_not_called()

    def test_naive_and_invalid_boundaries_are_rejected(self):
        for value in ["2026-11-21T09:00:00", "not-a-time"]:
            with self.assertRaises(argparse.ArgumentTypeError):
                preflight.parse_not_before(value)

    def test_naive_clock_never_invokes_subprocess(self):
        with patch.object(preflight.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                preflight.collect(self.boundary.replace(tzinfo=None), self.boundary)
        run.assert_not_called()


unittest.main()
