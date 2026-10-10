import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from harness import run
from harness.state import lease


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        for name, value in {
            "app/.fvmrc": '{"flutter":"3.44.2"}',
            "app/pubspec.lock": "locked",
            "app/lib/main.dart": "void main() {}",
            "app/lib/custom.dart": "void main() {}",
            "app/assets/deliveries.csv": "test csv",
            "app/test/example_test.dart": "void main() {}",
            "app/integration_test/example_test.dart": "void main() {}",
            "harness/example.py": "# source",
            "harness/project/work.json": '{"tasks":[]}',
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        self.locks = self.root / "harness/runs/locks"
        self.addCleanup(self.temp.cleanup)

    def cli(self, arguments, execute=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(run, "ROOT", self.root), patch.object(run, "RUNS", self.root / "harness/runs"), patch.object(sys, "argv", ["run.py", *arguments]), patch.object(sys, "stdout", out), patch.object(sys, "stderr", err), patch.object(run, "subprocess_stage", side_effect=execute or self.stage):
            try:
                code = run.main()
            except SystemExit as error:
                code = error.code
        return code, out.getvalue() + err.getvalue()

    @staticmethod
    def stage(argv, cwd, log, timeout, lock_fds, on_spawn, context=None):
        log.write_text("fixture output\n")
        return 0

    def test_configured_build_and_integration_plan_are_explicit(self):
        options = {"configuration": "demo", "build_mode": "profile", "ios_target": "device", "entrypoint": "lib/custom.dart", "device": "task-device"}
        plan = run.stages("build", self.root / "run", "candidate", options=options, root=self.root)
        command = plan[-1][1]
        self.assertIn("--profile", command)
        self.assertIn("--no-codesign", command)
        self.assertIn("--dart-define=OCEAN_MODE=demo", command)
        self.assertIn("lib/custom.dart", command)
        integration = run.stages("integration", self.root / "run", "candidate", targets=["integration_test/example_test.dart"], options=options, root=self.root)
        self.assertIn("task-device", integration[-1][1])
        self.assertEqual(integration[-1][1][-1], "integration_test/example_test.dart")
        format_stage = next(x for x in run.stages("quality", self.root / "run", "candidate", options=options, root=self.root) if x[0] == "format")
        self.assertIn("integration_test", format_stage[1])

    def test_invalid_paths_missing_device_and_simulator_modes_reject_before_execution(self):
        cases = [
            ["build", "--build-mode", "profile"],
            ["build", "--build-mode", "release"],
            ["build", "--entrypoint", "../outside.dart"],
            ["test", "--target", "integration_test/example_test.dart"],
            ["integration", "--target", "integration_test/example_test.dart"],
            ["integration", "--device", "task", "--target", "test/example_test.dart"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                executed = []
                code, _ = self.cli(arguments, lambda *args: executed.append(args))
                self.assertEqual(code, 2)
                self.assertFalse(executed)
        external = self.root / "outside.dart"
        external.write_text("external")
        (self.root / "app/lib/escape.dart").symlink_to(external)
        self.assertEqual(self.cli(["build", "--entrypoint", "lib/escape.dart"])[0], 2)

    def test_resume_rejects_changed_configuration_targets_and_stage_plan(self):
        self.assertEqual(self.cli(["test", "--target", "test/example_test.dart"])[0], 0)
        directory = next(path.parent for path in (self.root / "harness/runs").glob("*/report.json"))
        saved = json.loads((directory / "report.json").read_text())
        saved["job"]["pid"] = None
        run.save(directory / "report.json", saved)
        for arguments in (["test", "--configuration", "demo", "--target", "test/example_test.dart"], ["test"]):
            code, message = self.cli([*arguments, "--resume", str(directory)])
            self.assertEqual(code, 1)
            self.assertIn("stage options differ", message)
        saved["stage_spec"][0]["command"].append("tampered")
        run.save(directory / "report.json", saved)
        code, message = self.cli(["test", "--target", "test/example_test.dart", "--resume", str(directory)])
        self.assertEqual(code, 1)
        self.assertIn("stage plan differs", message)

    def test_isolated_copy_excludes_generated_outputs_preserves_source_and_cleans(self):
        (self.root / "app/build").mkdir()
        (self.root / "app/build/private-output").write_text("do not copy")
        fingerprint = run.checks.fingerprint(self.root)
        with run.isolated_workspace(self.root, fingerprint) as isolated:
            self.assertFalse((isolated / "app/build").exists())
            self.assertTrue((isolated / "app/lib/custom.dart").exists())
            self.assertTrue((isolated / "harness/project/work.json").exists())
            self.assertEqual(run.checks.fingerprint(isolated), fingerprint)
        self.assertFalse(isolated.exists())
        self.assertTrue((self.root / "app/build/private-output").exists())

    def test_isolated_clone_source_mutation_is_stale_even_when_origin_is_unchanged(self):
        fingerprint = run.checks.fingerprint(self.root)
        def mutation(argv, cwd, log, timeout, lock_fds, on_spawn, context=None):
            self.stage(argv, cwd, log, timeout, lock_fds, on_spawn, context)
            (cwd / "app/lib/main.dart").write_text("changed clone source")
            return 0
        code, message = self.cli(["check", "--isolated"], mutation)
        self.assertEqual(code, 1)
        self.assertIn("execution source changed", message)
        report = json.loads(next((self.root / "harness/runs").glob("*/report.json")).read_text())
        self.assertEqual(report["job"]["status"], "stale")
        self.assertEqual(report["candidate_after"]["source_fingerprint"], fingerprint)
        self.assertNotEqual(report["execution_candidate_after"], report["candidate"])
        self.assertTrue(report["isolation"]["cleaned"])
        self.assertEqual((self.root / "app/lib/main.dart").read_text(), "void main() {}")

    def test_inherited_lease_proof_rejects_fresh_descriptor_and_wrong_inode(self):
        with lease(["app-workspace", "device:task"], self.root / "held", self.locks) as context:
            self.assertEqual(run.require_lease_context(context, self.root), context["lock_fds"])
            resource = context["resources"][0]
            path = self.locks / (run.hashlib.sha256(resource.encode()).hexdigest() + ".lock")
            with path.open("a+") as fresh:
                with self.assertRaisesRegex(ValueError, "invalid inherited lease"):
                    run.require_lease_context({**context, "lock_fds": [fresh.fileno(), *context["lock_fds"][1:]]}, self.root)
            with (self.root / "other").open("w") as other:
                with self.assertRaisesRegex(ValueError, "lock inode"):
                    run.require_lease_context({**context, "lock_fds": [other.fileno(), *context["lock_fds"][1:]]}, self.root)
        with path.open("a+") as stale:
            with self.assertRaisesRegex(ValueError, "not held"):
                run.require_lease_context({**context, "lock_fds": [stale.fileno(), *context["lock_fds"][1:]]}, self.root)

    def test_artifact_is_retained_with_file_and_archive_hashes(self):
        application = self.root / "app/build/ios/iphonesimulator/Runner.app"
        application.mkdir(parents=True)
        (application / "Runner").write_bytes(b"test executable")
        options = {"configuration": "demo", "build_mode": "debug", "ios_target": "simulator", "entrypoint": "lib/main.dart"}
        output = self.root / "harness/runs/artifacts"
        output.mkdir(parents=True)
        value = run.preserve_artifact(self.root, output, "ios-build", options)
        manifest = json.loads((output / "artifact-ios-build/manifest.json").read_text())
        self.assertEqual(value["sha256"], run.sha(value["path"]))
        self.assertEqual(manifest["files"][0]["sha256"], run.sha(application / "Runner"))
        self.assertEqual(value["entrypoint"], "lib/main.dart")
        self.assertEqual(manifest["entrypoint"], "lib/main.dart")
        self.assertFalse(value["signed_for_production"])

    def test_resume_cleanup_requires_task_path_and_matching_ownership(self):
        directory = Path(tempfile.mkdtemp(prefix="ocean-harness-")).resolve()
        self.addCleanup(lambda: run.shutil.rmtree(directory, ignore_errors=True))
        report = {"execution_root": str(directory), "isolation": {"task_owned": True}, "candidate": {"source_fingerprint": "candidate"}}
        run.save(directory / ".harness-isolation.json", {"source_root": str(self.root), "source_fingerprint": "wrong"})
        with self.assertRaisesRegex(ValueError, "marker mismatch"):
            run.cleanup_previous_isolation(report, self.root)
        self.assertTrue(directory.exists())
        run.save(directory / ".harness-isolation.json", {"source_root": str(self.root), "source_fingerprint": "candidate"})
        run.cleanup_previous_isolation(report, self.root)
        self.assertFalse(directory.exists())

    def test_context_survives_wrapper_and_rejects_mutating_resources_conflict(self):
        with lease(["app-workspace"], self.root / "held", self.locks):
            code, output = self.cli(["pub"])
            self.assertEqual(code, 1)
            self.assertIn("busy", output)
        with lease(["app-workspace"], self.root / "held", self.locks) as context:
            for name in ("run.py", "checks.py", "gate.py", "state.py", "native_workbench.py"):
                run.shutil.copy2(Path(run.__file__).parent / name, self.root / "harness" / name)
            code = "import json,sys; from harness.run import require_lease_context; require_lease_context(json.loads(sys.argv[1]), __import__('pathlib').Path(sys.argv[2]))"
            log = self.root / "wrapper.log"
            with patch.object(run, "ROOT", self.root):
                result = run.subprocess_stage([sys.executable, "-c", code, json.dumps(context), str(self.root)], Path(__file__).resolve().parents[2], log, 20, context["lock_fds"], lambda pid: None, context)
            self.assertEqual(result, 0, log.read_text())


if __name__ == "__main__":
    unittest.main()
