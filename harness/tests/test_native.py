import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from harness import native
from harness.state import lease


class NativeCleanupTests(unittest.TestCase):
    def test_failed_boot_and_shutdown_still_delete_only_the_created_device(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            application = root / "app/build/ios/iphonesimulator/Runner.app"
            application.mkdir(parents=True)
            (application / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.test"}))
            calls = []
            def simctl(argv, **kwargs):
                calls.append(argv)
                action = argv[2]
                if action == "create":
                    return subprocess.CompletedProcess(argv, 0, "task-device\n", "")
                if action in ("boot", "shutdown"):
                    return subprocess.CompletedProcess(argv, 1, "", f"{action} failed")
                return subprocess.CompletedProcess(argv, 0, "", "")
            output = root / "output"
            with lease(["app-workspace", "device:ios-task-simulator"], root / "run", root / "harness/runs/locks") as context:
                candidate = native.runner.checks.fingerprint(root)
                with patch.object(native, "ROOT", root), patch.object(sys, "argv", ["native", "--output", str(output), "--candidate", candidate, "--lease-context", json.dumps(context)]), patch.object(native.subprocess, "run", side_effect=simctl), patch.object(sys, "stdout", io.StringIO()):
                    self.assertEqual(native.main(), 1)
            self.assertEqual([argv[2] for argv in calls], ["create", "boot", "shutdown", "delete"])
            self.assertTrue(all(argv[3] == "task-device" for argv in calls[1:]))
            report = json.loads((output / "result.json").read_text())
            self.assertTrue(report["device_cleaned"])
            self.assertIn("boot failed", report["error"])
            self.assertIn("shutdown failed", report["shutdown_error"])

    def test_direct_native_claim_cannot_bypass_leases(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(native, "ROOT", root), patch.object(sys, "argv", ["native", "--output", str(root / "output"), "--candidate", "test", "--lease-context", "{}"]), patch.object(native.subprocess, "run") as simctl, patch.object(sys, "stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    native.main()
                self.assertEqual(error.exception.code, 2)
                simctl.assert_not_called()
                self.assertFalse((root / "output").exists())

    def test_direct_workbench_claim_cannot_bypass_leases_or_start_services(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(native, "ROOT", root), patch.object(sys, "argv", ["native", "--scope", "workbench", "--output", str(root / "output"), "--candidate", "test", "--lease-context", "{}"]), patch.object(native.native_workbench, "execute") as execute, patch.object(sys, "stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    native.main()
                self.assertEqual(error.exception.code, 2)
                execute.assert_not_called()
                self.assertFalse((root / "output").exists())

    def test_startup_cleanup_failure_does_not_claim_pass_or_process_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            application = root / "app/build/ios/iphonesimulator/Runner.app"
            application.mkdir(parents=True)
            (application / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.test"}))
            def simctl(argv, **kwargs):
                action = argv[2]
                if action == "create": value = "task-device"
                elif action == "get_app_container": value = str(root / "data")
                elif action == "launch": value = f"dev.test: {os.getpid()}"
                elif action == "io":
                    Path(argv[-1]).write_bytes(b"screenshot fixture")
                    value = ""
                elif action == "delete": return subprocess.CompletedProcess(argv, 1, "", "controlled delete failure")
                else: value = ""
                return subprocess.CompletedProcess(argv, 0, value, "")
            output = root / "output"
            with lease(["app-workspace", "device:ios-task-simulator"], root / "run", root / "harness/runs/locks") as context:
                arguments = ["native", "--output", str(output), "--candidate", native.runner.checks.fingerprint(root), "--scope", "startup", "--lease-context", json.dumps(context)]
                with patch.object(native, "ROOT", root), patch.object(sys, "argv", arguments), patch.object(native.subprocess, "run", side_effect=simctl), patch.object(native.time, "sleep"), patch.object(sys, "stdout", io.StringIO()):
                    self.assertEqual(native.main(), 1)
            report = json.loads((output / "result.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertFalse(report["process_restart"])
            self.assertEqual(report["scope"], "startup-smoke")
            self.assertIn("controlled delete failure", report["cleanup_error"])


if __name__ == "__main__":
    unittest.main()
