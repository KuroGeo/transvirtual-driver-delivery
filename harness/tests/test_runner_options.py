"""CLI acceptance options cannot bypass scope, provenance, or fresh evaluation."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from harness import run


class AcceptanceRunnerOptionsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "harness").mkdir()
        for name, value in {
            "app/lib/main.dart": "void main() {}",
            "app/.fvmrc": '{"flutter":"3.44.2"}',
            "app/pubspec.lock": "locked",
            "app/assets/deliveries.csv": "fixture",
            "app/integration_test/workbench_entry.dart": "void main() {}",
            "app/integration_test/workbench_driver.dart": "void main() {}",
            "app/integration_test/acceptance_driver.dart": "void main() {}",
        }.items():
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)

    def cli(self, arguments, execute):
        output = io.StringIO()
        with patch.object(run, "ROOT", self.root), patch.object(run, "RUNS", self.root / "harness/runs"), patch.object(sys, "argv", ["run.py", *arguments]), patch.object(sys, "stdout", output), patch.object(sys, "stderr", output), patch.object(run, "subprocess_stage", side_effect=execute):
            try:
                code = run.main()
            except SystemExit as error:
                code = error.code
        return code, output.getvalue()

    def test_invalid_acceptance_options_never_spawn(self):
        calls = []
        invalid = [
            ["build", "--scenario", "N1"],
            ["native", "--scope", "startup", "--content-size", "large"],
            ["native", "--scope", "workbench", "--scenario", "N1"],
            ["native", "--scope", "workbench", "--driver-target", "integration_test/acceptance_driver.dart", "--reduce-motion"],
            ["native", "--scope", "workbench", "--driver-target", "integration_test/acceptance_driver.dart", "--scenario", "N5", "--migration-fault"],
            ["native", "--scope", "workbench", "--driver-target", "integration_test/acceptance_driver.dart", "--scenario", "N2", "--cold-fixture", "viewport-corrupt"],
            ["native", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-26-4;echo"],
            ["native", "--device-type", "user-device"],
            ["quality", "--runtime", "com.apple.CoreSimulator.SimRuntime.iOS-26-4"],
        ]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.cli(arguments, lambda *args: calls.append(args))[0], 2)
        self.assertFalse(calls)

    def test_system_and_fixture_options_reach_only_native_stage(self):
        options = {
            "configuration": "demo", "build_mode": "debug", "ios_target": "simulator", "scope": "workbench",
            "driver_target": "integration_test/acceptance_driver.dart", "fixture": run.native_workbench.LEGACY,
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
            "device_type": "com.apple.CoreSimulator.SimDeviceType.iPhone-17e",
            "scenario": "N6", "content_size": "accessibility-extra-extra-extra-large", "reduce_motion": True,
            "migration_fault": True, "initial_tiles": "503", "cold_fixture": "none",
        }
        plan = run.stages("native", self.root / "run", "a" * 64, options=options, root=self.root)
        command = plan[-1][1]
        for key in ("runtime", "device_type", "scenario", "content_size", "initial_tiles", "cold_fixture"):
            position = command.index("--" + key.replace("_", "-"))
            self.assertEqual(command[position + 1], options[key])
        self.assertIn("--reduce-motion", command)
        self.assertIn("--migration-fault", command)
        self.assertEqual(command[command.index("--driver-target") + 1], options["driver_target"])
        build = plan[-2][1]
        self.assertIn(run.native_workbench.ENTRY, build)
        self.assertNotIn("--migration-fault", build)

    def test_local_gate_resume_rechecks_changed_external_evidence(self):
        manifest = self.root / "local-evidence.json"
        manifest.write_text('{"accepted":true}')
        reads = []

        def evaluate_stage(argv, cwd, log, timeout, lock_fds, on_spawn, context=None, **kwargs):
            self.assertIn("_local_gate", argv)
            data = json.loads(manifest.read_text())
            reads.append(data)
            log.write_text(json.dumps(data))
            code = 0 if data["accepted"] else 1
            on_spawn(123456789)
            kwargs["on_finish"]({"fixture": True, "returncode": code, "wrapper_reaped": True, "group_alive": False})
            return code

        args = ["local-gate", "--manifest", str(manifest)]
        self.assertEqual(self.cli(args, evaluate_stage)[0], 0)
        directory = next((self.root / "harness/runs").glob("*-local-gate"))
        # This in-process CLI fixture has no prior OS job to reap. Existing
        # state tests separately verify real live PID/flock resume rejection.
        saved, leaf, mirror = run.resume_report(directory)
        saved["job"]["pid"] = None
        run.save_attempt(directory, leaf.parent, saved, mirror)
        manifest.write_text('{"accepted":false}')
        code, _ = self.cli([*args, "--resume", str(directory)], evaluate_stage)
        self.assertEqual(code, 1)
        self.assertEqual(reads, [{"accepted": True}, {"accepted": False}])

    def test_manifest_loader_rejects_ambiguous_and_nonfinite_json(self):
        manifest = self.root / "local-evidence.json"
        for data in ('{"candidate":"a","candidate":"b"}', '{"scale":NaN}', '{"scale":Infinity}', '{"scale":1e309}', '[]', '{'):
            with self.subTest(data=data):
                manifest.write_text(data)
                with self.assertRaises(ValueError):
                    run.read_manifest(manifest)

    def test_manifest_loader_rejects_symlinks_and_empty_files(self):
        manifest = self.root / "local-evidence.json"
        manifest.write_text('{"candidate":"a"}')
        link = self.root / "linked-evidence.json"
        link.symlink_to(manifest)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            run.read_manifest(link)
        manifest.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "bytes"):
            run.read_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
