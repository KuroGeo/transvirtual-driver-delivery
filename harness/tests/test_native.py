import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from harness import native


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
            with patch.object(native, "ROOT", root), patch.object(sys, "argv", ["native", "--output", str(output), "--candidate", "test-candidate"]), patch.object(native.subprocess, "run", side_effect=simctl), patch.object(sys, "stdout", io.StringIO()):
                self.assertEqual(native.main(), 1)
            self.assertEqual([argv[2] for argv in calls], ["create", "boot", "shutdown", "delete"])
            self.assertTrue(all(argv[3] == "task-device" for argv in calls[1:]))
            report = json.loads((output / "result.json").read_text())
            self.assertTrue(report["device_cleaned"])
            self.assertIn("boot failed", report["error"])
            self.assertIn("shutdown failed", report["shutdown_error"])


if __name__ == "__main__":
    unittest.main()
