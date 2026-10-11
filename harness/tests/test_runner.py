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
    def stage(argv, cwd, log, timeout, lock_fds, on_spawn, context=None, **kwargs):
        log.write_text("fixture output\n")
        on_spawn(123456789)
        if kwargs.get("on_finish"):
            kwargs["on_finish"]({"fixture": True, "returncode": 0, "wrapper_reaped": True, "group_alive": False})
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
        saved, leaf, mirror = run.resume_report(directory)
        saved["job"]["pid"] = None
        run.save_attempt(directory, leaf.parent, saved, mirror)
        for arguments in (["test", "--configuration", "demo", "--target", "test/example_test.dart"], ["test"]):
            code, message = self.cli([*arguments, "--resume", str(directory)])
            self.assertEqual(code, 1)
            self.assertIn("stage options differ", message)
        saved["stage_spec"][0]["command"].append("tampered")
        run.save_attempt(directory, leaf.parent, saved, mirror)
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
        def mutation(argv, cwd, log, timeout, lock_fds, on_spawn, context=None, **kwargs):
            self.stage(argv, cwd, log, timeout, lock_fds, on_spawn, context, **kwargs)
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
            for name in ("run.py", "checks.py", "next_phase.py", "f1.py", "gate.py", "state.py", "native_workbench.py"):
                run.shutil.copy2(Path(run.__file__).parent / name, self.root / "harness" / name)
            code = "import json,sys; from harness.run import require_lease_context; require_lease_context(json.loads(sys.argv[1]), __import__('pathlib').Path(sys.argv[2]))"
            log = self.root / "wrapper.log"
            with patch.object(run, "ROOT", self.root):
                result = run.subprocess_stage([sys.executable, "-c", code, json.dumps(context), str(self.root)], Path(__file__).resolve().parents[2], log, 20, context["lock_fds"], lambda pid: None, context)
            self.assertEqual(result, 0, log.read_text())

    def test_exception_finalizer_records_terminal_raw_log_and_actual_completion(self):
        cases = ((subprocess.TimeoutExpired(["fixture"], 1), "timed_out"),
                 (InterruptedError("fixture TERM"), "interrupted"),
                 (OSError("fixture spawn failed"), "failed"))
        for error, expected in cases:
            with self.subTest(error=type(error).__name__):
                def fail(argv, cwd, log, timeout, lock_fds, on_spawn, context=None, **kwargs):
                    log.write_bytes(b"")
                    spawned = type(error) is not OSError
                    if spawned:
                        on_spawn(123456789)
                    kwargs["on_finish"]({"fixture": True, "spawned": spawned, "returncode": -15 if spawned else None,
                                          "wrapper_reaped": spawned, "group_alive": False})
                    raise error
                code, _ = self.cli(["check"], fail)
                self.assertEqual(code, 1)
                directory = max((self.root / "harness/runs").glob("*-check"))
                report, leaf, _ = run.resume_report(directory)
                stage = report["stages"][0]
                self.assertEqual(stage["status"], expected)
                self.assertEqual(stage["exit_code"], -15 if expected != "failed" else None)
                self.assertEqual(stage["sha256"], run.sha(stage["log_path"]))
                self.assertEqual(stage["log_bytes"], 0)
                self.assertGreaterEqual(stage["elapsed_seconds"], 0)
                self.assertEqual(stage["error"]["type"], type(error).__name__)
                self.assertEqual(leaf.parent.name, "000001")
                self.assertFalse(any(item["status"] == "running" for item in report["stages"]))

    def test_resume_keeps_prior_attempt_bytes_and_only_reuses_matching_passed_logs(self):
        calls = []
        def execute(argv, cwd, log, timeout, lock_fds, on_spawn, context=None, **kwargs):
            calls.append(list(argv))
            code = 1 if "test" in argv and len(calls) == 3 else 0
            log.write_text("fixture first failure" if code else "fixture success")
            on_spawn(123456789)
            kwargs["on_finish"]({"fixture": True, "returncode": code, "wrapper_reaped": True, "group_alive": False})
            return code
        arguments = ["test", "--target", "test/example_test.dart"]
        self.assertEqual(self.cli(arguments, execute)[0], 1)
        directory = next((self.root / "harness/runs").glob("*-test"))
        first, first_leaf, _ = run.resume_report(directory)
        original = {path: path.read_bytes() for path in first_leaf.parent.iterdir() if path.is_file()}
        with patch.object(run.state, "_pid_alive", return_value=False):
            self.assertEqual(self.cli([*arguments, "--resume", str(directory)], execute)[0], 0)
        second, second_leaf, _ = run.resume_report(directory)
        self.assertEqual(second_leaf.parent.name, "000002")
        self.assertEqual(second["parent_attempt"]["sha256"], run.sha(first_leaf))
        self.assertEqual(second["stages"][0]["log_path"], first["stages"][0]["log_path"])
        self.assertIn("reused_from", second["stages"][0])
        self.assertNotIn("reused_from", second["stages"][1])  # locked pub always reruns
        self.assertNotIn("reused_from", second["stages"][2])
        self.assertEqual(len(calls), 5)
        for path, content in original.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertNotEqual(first["stages"][1]["log_path"], second["stages"][1]["log_path"])

    def test_modern_resume_rejects_missing_pointer_mirror_tampering_and_leaf_tampering(self):
        self.assertEqual(self.cli(["check"])[0], 0)
        directory = next((self.root / "harness/runs").glob("*-check"))
        _, leaf, _ = run.resume_report(directory)
        pointer = directory / "latest.json"
        raw_pointer = pointer.read_bytes()
        pointer.unlink()
        with self.assertRaisesRegex(ValueError, "pointer is missing"):
            run.resume_report(directory)
        pointer.write_bytes(raw_pointer)
        mirror = directory / "report.json"
        raw_mirror = mirror.read_bytes()
        mirror.write_text('{"status":"forged"}')
        with self.assertRaisesRegex(ValueError, "mirror differs"):
            run.resume_report(directory)
        mirror.write_bytes(raw_mirror)
        leaf.write_text('{"status":"forged"}')
        with self.assertRaisesRegex(ValueError, "hash/path mismatch"):
            run.resume_report(directory)

    def test_resume_rejects_actual_source_change_and_changed_passed_log(self):
        self.assertEqual(self.cli(["check"])[0], 0)
        directory = next((self.root / "harness/runs").glob("*-check"))
        report, leaf, _ = run.resume_report(directory)
        original_report = leaf.read_bytes()
        source = self.root / "app/lib/main.dart"
        original_source = source.read_bytes()
        source.write_text("void main() { print('changed'); }")
        with patch.object(run.state, "_pid_alive", return_value=False):
            code, message = self.cli(["check", "--resume", str(directory)])
        self.assertEqual(code, 1)
        self.assertIn("source_fingerprint changed", message)
        self.assertEqual(leaf.read_bytes(), original_report)
        self.assertEqual(len(list((directory / "attempts").iterdir())), 1)
        source.write_bytes(original_source)
        Path(report["stages"][0]["log_path"]).write_text("tampered external log")
        with patch.object(run.state, "_pid_alive", return_value=False):
            code, message = self.cli(["check", "--resume", str(directory)])
        self.assertEqual(code, 1)
        self.assertIn("saved log missing or changed", message)
        self.assertEqual(leaf.read_bytes(), original_report)

    def test_legacy_resume_preserves_original_report_logs_and_lease(self):
        self.assertEqual(self.cli(["test"])[0], 0)
        directory = next((self.root / "harness/runs").glob("*-test"))
        legacy, _, _ = run.resume_report(directory)
        legacy.pop("latest_attempt_report")
        legacy["job"]["pid"] = None  # explicit stopped legacy fixture
        for stage in legacy["stages"]:
            destination = directory / (stage["id"] + "-legacy.log")
            destination.write_bytes(Path(stage["log_path"]).read_bytes())
            stage["log_path"] = str(destination)
        run.shutil.rmtree(directory / "attempts")
        (directory / "latest.json").unlink()
        run.save(directory / "report.json", legacy)
        (directory / "lease.json").write_text('{"status":"legacy diagnostic"}')
        original = {path: path.read_bytes() for path in directory.iterdir() if path.is_file()}
        self.assertEqual(self.cli(["test", "--resume", str(directory)])[0], 0)
        report, leaf, mirror = run.resume_report(directory)
        self.assertEqual(mirror, "latest-report.json")
        self.assertEqual(leaf.parent.name, "000001")
        self.assertEqual(report["parent_attempt"]["path"], str(directory / "report.json"))
        for path, content in original.items():
            self.assertEqual(path.read_bytes(), content)

    def test_native_cleanup_resume_requires_current_owned_device_receipts(self):
        directory = self.root / "native-attempt"
        (directory / "native").mkdir(parents=True)
        udid = "12345678-1234-1234-1234-123456789ABC"
        options = {"scope": "workbench", "configuration": "demo", "entrypoint": run.native_workbench.ENTRY,
                   "runtime": "runtime", "device_type": "device-type"}
        report = {"command": "native", "candidate": {"source_fingerprint": "a" * 64}, "options": options,
                  "stages": [{"id": "workbench-smoke", "job_pid": 123456789, "completion": {"spawned": True}}]}
        native = {"candidate": "a" * 64, "configuration": "demo", "entrypoint": options["entrypoint"],
                  "device": {"udid": udid, "runtime": "runtime", "type": "device-type", "task_owned": True}, "device_cleaned": True,
                  "commands": [{"argv": ["xcrun", "simctl", "create", "OceanDelivery-Workbench", "device-type", "runtime"], "exit_code": 0, "stdout": udid},
                               {"argv": ["xcrun", "simctl", "delete", udid], "exit_code": 0}]}
        for changed in ({}, {**native, "candidate": "b" * 64}, {**native, "device_cleaned": False},
                        {**native, "device": {**native["device"], "task_owned": False}}, {**native, "commands": native["commands"][:1]},
                        {**native, "log_reader_cleanup_error": "fixture failed"}):
            with self.subTest(changed=changed):
                run.save(directory / "native/result.json", changed)
                with self.assertRaises(ValueError):
                    run.native_resume_ready(report, directory)
        run.save(directory / "native/result.json", native)
        run.native_resume_ready(report, directory)
        (directory / "native/result.json").unlink()
        with self.assertRaisesRegex(ValueError, "unknown"):
            run.native_resume_ready(report, directory)
        report["stages"][0].update(job_pid=None, completion={"spawned": False})
        run.native_resume_ready(report, directory)

    def test_native_attempt_spec_keeps_gate_run_normalization_and_fixed_grace(self):
        # Isolated execution source and retained run output are disjoint roots.
        # Both Runner and gate normalize workspace first, then attempt output.
        with tempfile.TemporaryDirectory(prefix="ocean-attempt-fixture-") as output:
            attempt = Path(output).resolve() / "attempts/000002"
            self.assertFalse(attempt.is_relative_to(self.root))
            options = {"configuration": "demo", "build_mode": "debug", "ios_target": "simulator", "scope": "workbench"}
            plan = run.stages("native", attempt, "a" * 64, options=options, root=self.root)
            spec = run.stage_spec(plan, self.root, attempt)
            self.assertIn("@run/native", spec[-1]["command"])
            self.assertIn("@inherited-lease", spec[-1]["command"])
        self.assertEqual(run.cleanup_grace("workbench-smoke"), 150)
        self.assertEqual(run.cleanup_grace("workbench-build"), 5)


if __name__ == "__main__":
    unittest.main()
