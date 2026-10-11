import argparse
from contextlib import closing
import io
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import zlib

from harness import native_workbench as workbench
from harness import run


UDID = "12345678-1234-1234-1234-123456789012"
CANDIDATE = "f" * 64
SESSION = "e" * 48
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


class WorkbenchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.container = self.root / "Devices" / UDID / "data/Containers/Data/Application/task-app"
        (self.container / "Documents").mkdir(parents=True)
        self.database = self.container / "Documents/ocean_delivery-demo.sqlite"
        with closing(sqlite3.connect(self.database)) as database, database:
            database.executescript("""
                PRAGMA user_version=2;
                CREATE TABLE datasets(id TEXT PRIMARY KEY);
                CREATE TABLE stops(id TEXT PRIMARY KEY, acknowledged_at INTEGER);
                CREATE TABLE outbox(seq INTEGER PRIMARY KEY, operation_id TEXT, dataset_id TEXT, stop_id TEXT);
                CREATE TABLE delivery_settings(dataset_id TEXT PRIMARY KEY, online INTEGER);
                INSERT INTO datasets VALUES('batch');
                INSERT INTO stops VALUES('stop',NULL);
                INSERT INTO outbox VALUES(7,'stable','batch','stop');
                INSERT INTO delivery_settings VALUES('batch',0);
            """)

    def request(self, fixture, path, value=None, authorized=True):
        headers = {"Content-Type": "application/json"}
        if authorized:
            headers["X-Ocean-Task"] = fixture.token
        request = Request(fixture.url + path, data=json.dumps(value).encode() if value is not None else None, headers=headers)
        return urlopen(request, timeout=3)

    def framed_post(self, fixture, headers, body, short=False):
        connection = HTTPConnection("127.0.0.1", fixture.server.server_port, timeout=3)
        try:
            connection.putrequest("POST", "/capture?token=" + fixture.token)
            connection.putheader("X-Ocean-Task", fixture.token)
            for key, value in headers:
                connection.putheader(key, value)
            connection.endheaders(body)
            if short:
                connection.sock.shutdown(socket.SHUT_WR)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def session(self, configuration="demo", **options):
        for name in ("harness/native.py", "harness/native_workbench.py", "harness/run.py", "app/" + workbench.ENTRY, "app/" + workbench.DRIVER, "app/integration_test/acceptance_driver.dart", "app/integration_test/support/native_acceptance_support.dart", "app/integration_test/support/native_workbench_bridge.dart", "app/integration_test/support/native_driver_support.dart", "app/integration_test/support/native_gesture_command.dart", "app/integration_test/support/native_gesture_extension.dart", "app/pubspec.lock", "app/assets/deliveries.csv"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("source fixture")
        (self.root / "app/lib").mkdir(exist_ok=True)
        (self.root / "app/lib/main.dart").write_text("void main() {}")
        (self.root / "app/.fvmrc").write_text('{"flutter":"3.44.2"}')
        application = self.root / "app/build/ios/iphonesimulator/Runner.app"
        application.mkdir(parents=True)
        (application / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.task"}))
        self.installed_app = self.root / "Devices" / UDID / "data/Containers/Bundle/Application/task-install/Runner.app"
        self.installed_app.mkdir(parents=True)
        (self.installed_app / "Runner").write_bytes(b"installed executable fixture")
        args = argparse.Namespace(**{"output": self.root / "output", "driver_target": None, "candidate": CANDIDATE, "configuration": configuration, "runtime": RUNTIME, "device_type": DEVICE_TYPE, "fixture": None, **options})
        session = workbench.Workbench(args, self.root, (51, 52))
        session.container = self.container
        return session

    @staticmethod
    def inventory(kind):
        return json.dumps({"runtimes": [{"identifier": RUNTIME, "isAvailable": True}]} if kind == "runtimes" else {"devicetypes": [{"identifier": DEVICE_TYPE}]})

    @staticmethod
    def launch_fixture():
        return argparse.Namespace(url="http://127.0.0.1:1234", token="b" * 48)

    @staticmethod
    def unified_event(pid=321, uri="http://127.0.0.1:4321/currentToken=/", **values):
        return {"processID": pid, "processImagePath": "/task/Runner.app/Runner", "senderImagePath": "/task/Flutter.framework/Flutter", "eventMessage": "The Dart VM service is listening on " + uri, **values}

    def fake_log_reader(self, session, directory):
        class Process:
            pid = 654
            returncode = None
            def poll(self):
                return self.returncode
            def terminate(self):
                self.returncode = -15
            def wait(self, timeout):
                return self.returncode
        session.log_reader = Process()
        session.log_started = 0
        session.log_record = {"argv": ["controlled-unit-stream"]}
        (directory / "unified.stream.json").write_text(json.dumps(self.unified_event(
            processImagePath=str(self.installed_app / "Runner"),
            senderImagePath=str(self.installed_app / "Frameworks/Flutter.framework/Flutter"))))

    def test_unified_vm_discovery_requires_actual_pid_engine_message_and_auth(self):
        valid = self.unified_event()
        text = "Filtering the log data\n[\n" + json.dumps(self.unified_event(pid=320)) + ",\n" + json.dumps(valid, indent=2) + ",\n"
        self.assertEqual(workbench.unified_vm_uri(text, 321), "http://127.0.0.1:4321/currentToken=/")
        prefixed = self.unified_event(eventMessage="flutter: " + valid["eventMessage"])
        self.assertEqual(workbench.unified_vm_uri(json.dumps(prefixed), 321), "http://127.0.0.1:4321/currentToken=/")
        self.assertIsNone(workbench.unified_vm_uri(json.dumps(valid)[:-2], 321))
        invalid = [
            self.unified_event(pid=True), self.unified_event(processImagePath="/user/Other"),
            self.unified_event(senderImagePath="/user/Library"),
            self.unified_event(eventMessage="tile failed http://127.0.0.1:4321/currentToken=/"),
            self.unified_event(eventMessage="flutter: flutter: " + valid["eventMessage"]),
            self.unified_event(eventMessage="Flutter: " + valid["eventMessage"]),
            self.unified_event(eventMessage="other: " + valid["eventMessage"]),
            self.unified_event(uri="http://127.0.0.1:4321/"),
            self.unified_event(uri="http://foreign.example:4321/currentToken=/"),
            self.unified_event(uri="http://127.0.0.1:99999/currentToken=/"),
            self.unified_event(uri="http://user:secret@127.0.0.1:4321/currentToken=/"),
            self.unified_event(uri="http://127.0.0.1:4321/currentToken=/?unexpected=1"),
        ]
        for event in invalid:
            with self.subTest(event=event):
                self.assertIsNone(workbench.unified_vm_uri(json.dumps(event), 321))
        partial_nested = '{"outer": ' + json.dumps(valid)
        self.assertIsNone(workbench.unified_vm_uri(partial_nested, 321))
        with self.assertRaises(ValueError):
            workbench.unified_vm_uri(json.dumps([valid, self.unified_event(uri="http://127.0.0.1:4322/otherToken=/")]), 321)

    def test_unified_reader_inherits_resource_descriptors_and_is_reaped(self):
        session = self.session()
        session.device = UDID
        directory = session.output / "saved"
        directory.mkdir()
        class Process:
            pid = 654
            returncode = None
            def poll(self):
                return self.returncode
            def terminate(self):
                self.returncode = -15
            def wait(self, timeout):
                return self.returncode
        child = Process()
        with patch.object(workbench.subprocess, "Popen", return_value=child) as spawn:
            session.start_log_reader(directory)
            self.assertEqual(spawn.call_args.kwargs["pass_fds"], (51, 52))
            self.assertIn(UDID, spawn.call_args.args[0])
            self.assertIn("stream", spawn.call_args.args[0])
            session.stop_log_reader()
        self.assertIsNone(session.log_reader)
        self.assertEqual(session.log_streams, [])
        self.assertEqual(session.report["commands"][-1]["exit_code"], -15)
        self.assertTrue(session.report["commands"][-1]["reaped"])

    def test_persisted_vm_requires_complete_current_pid_exact_installed_app_and_auth(self):
        self.session()
        executable = self.installed_app / "Runner"
        workbench.installed_bundle(self.installed_app, UDID, "Runner.app", "Runner")
        valid = self.unified_event(processImagePath=str(executable), senderImagePath=str(self.installed_app / "Frameworks/Flutter.framework/Flutter"))
        valid["eventMessage"] = "flutter: " + valid["eventMessage"]
        raw = json.dumps([valid])
        self.assertEqual(workbench.persisted_vm_uri(raw, 321, "Runner", executable), "http://127.0.0.1:4321/currentToken=/")
        rejected = [json.dumps([{**valid, "processID": 320}]), raw[:-1], raw[:-2], json.dumps(valid),
            json.dumps([{**valid, "processImagePath": "/user/Other.app/Runner"}]),
            json.dumps([{**valid, "senderImagePath": "/user/Flutter.framework/Flutter"}]),
            json.dumps([{**valid, "eventMessage": "The Dart VM service is listening on http://127.0.0.1:4321/"}]),
            json.dumps([{**valid, "eventMessage": "other: " + valid["eventMessage"]}])]
        for text in rejected:
            with self.subTest(text=text):
                self.assertIsNone(workbench.persisted_vm_uri(text, 321, "Runner", executable))
        for path, udid in ((self.installed_app, "other-device"), (self.container, UDID)):
            with self.assertRaises(ValueError):
                workbench.installed_bundle(path, udid, "Runner.app", "Runner")
        linked = self.root / "linked.app"
        linked.symlink_to(self.installed_app, target_is_directory=True)
        with self.assertRaises(ValueError):
            workbench.installed_bundle(linked, UDID, "Runner.app", "Runner")

    def test_lost_startup_stream_uses_retained_task_pid_show_with_same_identity(self):
        session = self.session()
        session.device = UDID
        fixture = self.launch_fixture()
        calls = []
        valid = self.unified_event(processImagePath=str(self.installed_app / "Runner"), senderImagePath=str(self.installed_app / "Frameworks/Flutter.framework/Flutter"))
        def reader(directory):
            self.fake_log_reader(session, directory)
            (directory / "unified.stream.json").write_text("Filtering the log data\n[]\n")
        def command(*arguments, **kwargs):
            calls.append((arguments, kwargs))
            if arguments[0] == "get_app_container": return str(self.installed_app)
            if arguments[0] == "launch": return "dev.task: 321"
            return json.dumps([valid])
        with patch.object(session, "command", side_effect=command), patch.object(session, "start_log_reader", side_effect=reader), patch.object(session, "alive", return_value=True):
            self.assertEqual(session.launch("saved", fixture), (321, "http://127.0.0.1:4321/currentToken=/"))
        session.stop_log_reader()
        launch = session.report["launches"][-1]
        self.assertEqual(launch["vm_discovery_source"], "persisted-show")
        artifact = launch["vm_discovery_artifact"]
        self.assertEqual(workbench.digest(session.output / artifact["path"]), artifact["sha256"])
        show, options = calls[-1]
        self.assertEqual(show[:4], ("spawn", UDID, "log", "show"))
        self.assertEqual(show[show.index("--process") + 1], "321")
        self.assertIn(str(self.installed_app / "Runner"), show[-1])
        self.assertLessEqual(options["timeout"], 5)
        self.assertEqual(launch["launch_config"]["session"], session.session)

    def test_persisted_vm_fallback_never_extends_the_original_45_second_deadline(self):
        session = self.session()
        session.device = UDID
        fixture = self.launch_fixture()
        clock = {"calls": 0, "value": 44}
        def now():
            clock["calls"] += 1
            return 0 if clock["calls"] == 1 else clock["value"]
        def reader(directory):
            self.fake_log_reader(session, directory)
            (directory / "unified.stream.json").write_text("[]")
        def command(*arguments, **kwargs):
            if arguments[0] == "get_app_container": return str(self.installed_app)
            if arguments[0] == "launch": return "dev.task: 321"
            self.assertLessEqual(kwargs["timeout"], 1)
            clock["value"] = 46
            return json.dumps([self.unified_event(processImagePath=str(self.installed_app / "Runner"), senderImagePath=str(self.installed_app / "Frameworks/Flutter.framework/Flutter"))])
        with patch.object(session, "command", side_effect=command), patch.object(session, "start_log_reader", side_effect=reader), patch.object(session, "alive", return_value=True), patch.object(workbench.time, "monotonic", side_effect=now):
            with self.assertRaises(TimeoutError):
                session.launch("saved", fixture)
        session.stop_log_reader()
        self.assertNotIn("vm_uri_sha256", session.report["launches"][-1])
        self.assertTrue((session.output / "saved/discovery-show-01.json").is_file())

    def test_vm_discovery_failure_retains_os_diagnostics_with_absent_db(self):
        session = self.session()
        self.database.unlink()
        def command(*arguments, **kwargs):
            if arguments[0] == "list":
                return self.inventory(arguments[1])
            if arguments[0] == "create":
                return UDID
            if arguments[0] == "get_app_container":
                return str(self.container)
            if arguments[0] == "io":
                Path(arguments[-1]).write_bytes(workbench.TILE)
            if arguments[0] == "spawn":
                self.assertIn("--process", arguments)
                self.assertIn("321", arguments)
                return json.dumps([self.unified_event()])
            return ""
        def launch(phase, fixture):
            (session.output / phase).mkdir()
            session.pid, session.session = 321, "new-session"
            raise TimeoutError("controlled no VM discovery")
        with patch.object(session, "command", side_effect=command), patch.object(session, "launch", side_effect=launch), patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(session.execute(), 1)
        report = json.loads((session.output / "result.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["fault_cleanup"]["status"], "not_applicable")
        self.assertNotIn("fault_cleanup_error", report)
        self.assertTrue((session.output / "saved/failure-os.png").is_file())
        self.assertTrue((session.output / "saved/failure-unified-show.json").is_file())
        self.assertTrue(report["device_cleaned"])

    def test_runner_rejects_driver_fixture_scope_and_retains_effective_entry_resume_identity(self):
        self.session()
        (self.root / "app/integration_test/independent.dart").write_text("void main() {}")
        executed = []
        def stage(argv, cwd, log, timeout, descriptors, on_spawn, context, **kwargs):
            executed.append(argv)
            log.write_text("mock tooling stage; no device\n")
            on_spawn(123456789)
            kwargs["on_finish"]({"fixture": True, "returncode": 0, "wrapper_reaped": True, "group_alive": False})
            return 0
        def cli(arguments):
            with patch.object(run, "ROOT", self.root), patch.object(run, "RUNS", self.root / "harness/runs"), patch.object(sys, "argv", ["run", *arguments]), patch.object(run, "subprocess_stage", side_effect=stage), patch.object(sys, "stdout", io.StringIO()), patch.object(sys, "stderr", io.StringIO()):
                try:
                    return run.main()
                except SystemExit as error:
                    return error.code
        for arguments in (["build", "--entrypoint", workbench.ENTRY], ["native", "--scope", "startup", "--driver-target", workbench.DRIVER], ["quality", "--driver-target", workbench.DRIVER], ["native", "--scope", "workbench", "--driver-target", "../outside.dart"], ["native", "--scope", "workbench", "--fixture", workbench.LEGACY]):
            with self.subTest(arguments=arguments):
                self.assertEqual(cli(arguments), 2)
                self.assertFalse(executed)
        self.assertEqual(cli(["native", "--scope", "workbench"]), 0)
        report_path = next((self.root / "harness/runs").glob("*/report.json"))
        report = json.loads(report_path.read_text())
        self.assertEqual(report["options"]["entrypoint"], workbench.ENTRY)
        self.assertEqual(report["inputs"]["entrypoint"], workbench.ENTRY)
        self.assertEqual(report["options"]["driver_target"], workbench.DRIVER)
        self.assertEqual(report["stages"][-2]["artifact"]["entrypoint"], workbench.ENTRY)
        self.assertEqual(cli(["native", "--scope", "workbench", "--driver-target", "integration_test/independent.dart", "--resume", str(report_path.parent)]), 1)
        self.assertEqual(cli(["native", "--scope", "workbench", "--driver-target", "integration_test/independent.dart", "--fixture", workbench.LEGACY, "--resume", str(report_path.parent)]), 1)

    def test_genuine_legacy_fixture_preserves_original_schema_rows_and_sequence(self):
        self.database.unlink()
        source = self.root / "source.csv"
        source.write_text("reference,customer_name,address,latitude,longitude,status,time_window\n" + "\n".join(f"REF-{index},Customer{index},Street{index},-33.9,151.1,pending,08:00-10:00" for index in range(30)))
        output = self.root / "legacy-artifacts"
        receipt = workbench.seed_legacy(self.container, UDID, "demo", source, output)
        self.assertEqual(receipt["outbox_sequence"], [7, 11])
        with closing(sqlite3.connect(self.database)) as database:
            self.assertEqual(database.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(database.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").fetchall(), [("datasets",), ("outbox",), ("sqlite_sequence",), ("stops",)])
            columns = [row[1] for row in database.execute("PRAGMA table_info(stops)")]
            self.assertNotIn("note", columns)
            self.assertNotIn("recorded_at", columns)
            self.assertNotIn("time_window", columns)
            self.assertEqual(database.execute("SELECT seq,operation_id,reason FROM outbox ORDER BY seq").fetchall(), [(7, "legacy-operation-0", None), (11, "legacy-operation-1", "  Historical reason  ")])
            self.assertEqual(database.execute("SELECT seq FROM sqlite_sequence WHERE name='outbox'").fetchone()[0], 22)
            self.assertEqual(database.execute("SELECT acknowledged_at FROM stops WHERE operation_id='historically-acknowledged'").fetchone()[0], 1700000000000)
        self.assertEqual(receipt["backup_sha256"], workbench.digest(output / "legacy-before-launch.sqlite"))
        before = self.database.read_bytes()
        for values in ((self.container, UDID, "demo", source), (self.container, "foreign-device", "demo", source), (self.root, UDID, "demo", source)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                workbench.seed_legacy(*values, output)
        self.assertEqual(self.database.read_bytes(), before)

    def test_acceptance_options_and_actual_device_inventory_fail_closed(self):
        args = argparse.Namespace(fixture=None)
        self.assertIsNone(workbench.workbench_options(args, workbench.DRIVER)["scenario"])
        args.scenario = "N7"
        with self.assertRaises(ValueError):
            workbench.workbench_options(args, workbench.DRIVER)
        independent = "integration_test/acceptance_driver.dart"
        self.assertEqual(workbench.workbench_options(args, independent)["content_size"], "large")
        for key, value in (("scenario", "N8"), ("content_size", "huge"), ("reduce_motion", 1), ("initial_tiles", "public"), ("cold_fixture", "foreign-settings"), ("migration_fault", True)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                workbench.workbench_options(argparse.Namespace(**{"fixture": None, "scenario": "N7", key: value}), independent)
        self.assertTrue(workbench.workbench_options(argparse.Namespace(scenario="N6", fixture=workbench.LEGACY, migration_fault=True), independent)["migration_fault"])
        runtime, types = json.loads(self.inventory("runtimes")), json.loads(self.inventory("devicetypes"))
        workbench.available_device(RUNTIME, DEVICE_TYPE, runtime, types)
        for available in (False, 1, None):
            with self.subTest(available=available), self.assertRaises(ValueError):
                workbench.available_device(RUNTIME, DEVICE_TYPE, {"runtimes": [{"identifier": RUNTIME, "isAvailable": available}]}, types)
        for rt, device in (("booted", DEVICE_TYPE), (RUNTIME, "user-device"), (True, DEVICE_TYPE)):
            with self.subTest(runtime=rt, device=device), self.assertRaises(ValueError):
                workbench.device_identifiers(rt, device)
        with self.assertRaises(ValueError):
            workbench.available_device(RUNTIME, DEVICE_TYPE, runtime, {"devicetypes": []})

    def test_cold_viewport_fixture_preserves_business_online_and_nonfinite_raw_sql(self):
        with closing(sqlite3.connect(self.database)) as database, database:
            database.execute("ALTER TABLE stops ADD COLUMN dataset_id TEXT")
            database.execute("UPDATE stops SET dataset_id='batch'")
            for name in ("viewport_latitude", "viewport_longitude", "viewport_zoom"):
                database.execute(f"ALTER TABLE delivery_settings ADD COLUMN {name} REAL")
        before = workbench.sqlite_snapshot(self.container, "demo", self.root / "before.sqlite")
        for name in ("viewport-corrupt", "viewport-nonfinite"):
            with self.subTest(name=name):
                workbench.cold_settings_fixture(self.container, UDID, "demo", name)
                after = workbench.sqlite_snapshot(self.container, "demo", self.root / (name + ".sqlite"))
                for table in ("datasets", "stops", "outbox"):
                    self.assertEqual(after["tables"][table], before["tables"][table])
                settings = after["tables"]["delivery_settings"][0]
                self.assertEqual((settings["dataset_id"], settings["online"]), ("batch", 0))
                self.assertEqual(settings["viewport_latitude"], "bad" if name == "viewport-corrupt" else {"sqlite_nonfinite": "inf"})
                json.dumps(after, allow_nan=False)
        with closing(sqlite3.connect(self.database)) as database:
            self.assertEqual(database.execute("SELECT viewport_latitude FROM delivery_settings").fetchone()[0], float("inf"))
        for container, udid, name in ((self.container, "foreign", "viewport-corrupt"), (self.root, UDID, "viewport-corrupt"), (self.container, UDID, "foreign-settings")):
            with self.assertRaises(ValueError):
                workbench.cold_settings_fixture(container, udid, "demo", name)

    def test_genuine_migration_abort_capture_then_named_drop_and_retry_preserve_v1(self):
        session = self.session(scenario="N6", driver_target="integration_test/acceptance_driver.dart", fixture=workbench.LEGACY, migration_fault=True)
        self.database.unlink()
        source = self.root / "source.csv"
        source.write_text("reference,customer_name,address,latitude,longitude,status,time_window\n" + "\n".join(f"REF-{index},Customer{index},Street{index},-33.9,151.1,pending,08:00-10:00" for index in range(30)))
        workbench.seed_legacy(self.container, UDID, "demo", source, self.root / "legacy")
        workbench.migration_fault(self.container, UDID, "demo", install=True)
        session.device, session.session, session.pid, session.active_phase = UDID, SESSION, 321, "saved"
        session.migration_armed = True
        session.legacy_baseline = workbench.sqlite_snapshot(self.container, "demo", self.root / "armed.sqlite", legacy=True)
        def upgrade():
            with closing(sqlite3.connect(self.database)) as database, database:
                database.execute("BEGIN")
                for statement in ("ALTER TABLE stops ADD COLUMN time_window TEXT", "ALTER TABLE stops ADD COLUMN note TEXT", "ALTER TABLE stops ADD COLUMN recorded_at INTEGER", "ALTER TABLE outbox ADD COLUMN note TEXT", "ALTER TABLE outbox ADD COLUMN recorded_at INTEGER", "CREATE TABLE delivery_settings(dataset_id TEXT PRIMARY KEY,online INTEGER,viewport_latitude REAL,viewport_longitude REAL,viewport_zoom REAL)"):
                    database.execute(statement)
                database.execute("UPDATE stops SET time_window='08:00-10:00'")
                database.execute("PRAGMA user_version=2")
        with self.assertRaises(sqlite3.IntegrityError):
            upgrade()
        rollback = workbench.sqlite_snapshot(self.container, "demo", self.root / "rollback.sqlite", legacy=True)
        for key in ("tables", "schema", "sqlite_sequence"):
            self.assertEqual(rollback[key], session.legacy_baseline[key])
        self.assertEqual(rollback["user_version"], 1)
        with self.assertRaises(ValueError):
            session.clear_migration_fault()
        directory = session.output / "saved"
        directory.mkdir()
        session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, self.launch_fixture())
        snapshot = {"schema": 1, "processId": 321, "candidate": CANDIDATE, "configuration": "demo", "mode": "demo", "session": SESSION,
            "transport": "controlled-http-simulated", "databasePath": str(self.database), "launchConfigPath": session.launch_config["path"], "launchConfigByteLength": session.launch_config["byte_length"], "launchConfigSchema": 1,
            "model": None, "outbox": None, "bounds": {"reload-data": [{"centerHit": True}]}}
        snapshot_path = directory / "migration-rollback-snapshot.json"
        workbench.write_json(snapshot_path, snapshot)
        for changed in ({"processId": 320}, {"model": {"initialized": True}}, {"bounds": {"reload-data": [{"centerHit": False}]}}, {"bounds": {"retry-bootstrap": [{"centerHit": True}]}}, {"launchConfigByteLength": 1}):
            with self.subTest(changed=changed):
                workbench.write_json(snapshot_path, {**snapshot, **changed})
                with self.assertRaises(ValueError):
                    session.failed_boot_observation()
        workbench.write_json(snapshot_path, snapshot)
        (self.database.parent / workbench.JOURNAL).write_text(json.dumps({"source": "repository", "stage": "initialize_failed", "processId": 321, "candidate": CANDIDATE, "configuration": "demo", "session": SESSION}) + "\n")
        with patch.object(session, "command", side_effect=lambda *args, **kwargs: Path(args[-1]).write_bytes(workbench.TILE)):
            captured = session.capture("migration-rollback")
        self.assertEqual(captured["database"]["user_version"], 1)
        self.assertTrue(session.boot_failure_captured)
        session.clear_migration_fault()
        self.assertFalse(session.migration_armed)
        with closing(sqlite3.connect(self.database)) as database:
            self.assertEqual(database.execute("SELECT name FROM sqlite_master WHERE name=?", (workbench.MIGRATION_TRIGGER,)).fetchall(), [])
        upgrade()
        restored = workbench.sqlite_snapshot(self.container, "demo", self.root / "upgraded.sqlite")
        self.assertEqual(restored["user_version"], 2)
        self.assertEqual(workbench.outbox_identities(restored["tables"]["outbox"]), workbench.outbox_identities(rollback["tables"]["outbox"]))
        self.assertEqual(restored["sqlite_sequence"], rollback["sqlite_sequence"])
        with self.assertRaises(ValueError):
            workbench.migration_fault(self.container, UDID, "demo", install=True)

    def test_cold_fixture_waits_for_actual_saved_pid_exit_and_retains_both_backups(self):
        session = self.session(scenario="N5", driver_target="integration_test/acceptance_driver.dart", cold_fixture="viewport-corrupt")
        with closing(sqlite3.connect(self.database)) as database, database:
            database.execute("ALTER TABLE stops ADD COLUMN dataset_id TEXT")
            database.execute("UPDATE stops SET dataset_id='batch'")
            for name in ("viewport_latitude", "viewport_longitude", "viewport_zoom"):
                database.execute(f"ALTER TABLE delivery_settings ADD COLUMN {name} REAL")
        session.device, session.session, session.pid = UDID, SESSION, 321
        session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, self.launch_fixture())
        original = self.database.read_bytes()
        with patch.object(session, "alive", return_value=True), self.assertRaises(ValueError):
            session.prepare_cold_fixture()
        self.assertEqual(self.database.read_bytes(), original)
        self.assertFalse((session.output / "cold-before.sqlite").exists())
        with patch.object(session, "alive", return_value=False):
            session.prepare_cold_fixture()
        self.assertEqual(session.report["cold_fixture"]["after_terminated_pid"], 321)
        self.assertEqual(session.report["cold_fixture"]["before"]["tables"]["outbox"], session.report["cold_fixture"]["after"]["tables"]["outbox"])
        for artifact in session.report["artifacts"]:
            self.assertEqual(workbench.digest(session.output / artifact["path"]), artifact["sha256"])

    def test_migration_control_only_drops_one_explicit_armed_fixture(self):
        dropped = []
        with workbench.Fixture(self.root, lambda name: {}, lambda fault: None, lambda: dropped.append("named-trigger")) as fixture:
            for value in ({"migrationFault": "armed"}, {"migrationFault": True}, {"migrationFault": "arbitrary-sql"}):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    fixture.control(value)
            self.assertEqual(dropped, [])
            self.assertEqual(fixture.control({"migrationFault": "none"})["migrationFault"], "none")
            self.assertEqual(dropped, ["named-trigger"])
            with self.assertRaises(ValueError):
                fixture.control({"migrationFault": "none"})
        with workbench.Fixture(self.root, lambda name: {}, lambda fault: None) as fixture:
            with self.assertRaises(ValueError):
                fixture.control({"migrationFault": "none"})

    def test_os_controls_and_tile503_are_applied_before_launch_not_inferred_as_ui_success(self):
        session = self.session(scenario="N7", driver_target="integration_test/acceptance_driver.dart", content_size="accessibility-extra-extra-extra-large", reduce_motion=True, initial_tiles="503")
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            if args[0] == "list": return self.inventory(args[1])
            if args[0] == "create": return UDID
            if args[0] == "get_app_container": return str(self.container)
            return "attempted task setting"
        def launch(phase, fixture):
            self.assertEqual(fixture.state["tiles"], "503")
            raise RuntimeError("controlled stop after pre-mount fixture verification")
        with patch.object(session, "command", side_effect=command), patch.object(session, "launch", side_effect=launch), patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(session.execute(), 1)
        self.assertIn(("ui", UDID, "content_size", "accessibility-extra-extra-extra-large"), calls)
        self.assertIn(("spawn", UDID, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "YES"), calls)
        self.assertIn(("spawn", UDID, "notifyutil", "-p", "com.apple.Accessibility.ReduceMotionStatusDidChange"), calls)
        self.assertLess(calls.index(("spawn", UDID, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "YES")), calls.index(("spawn", UDID, "notifyutil", "-p", "com.apple.Accessibility.ReduceMotionStatusDidChange")))
        self.assertEqual(session.report["status"], "failed")
        self.assertIn("not inferred", session.report["os_controls"]["actual_mediaquery_proof"])
        self.assertIn("app/integration_test/support/native_acceptance_support.dart", session.report["inputs"])

    def test_failed_genuine_v1_boot_cleans_named_trigger_and_device_without_v2_fault_claim(self):
        session = self.session(scenario="N6", driver_target="integration_test/acceptance_driver.dart", fixture=workbench.LEGACY, migration_fault=True)
        self.database.unlink()
        (self.root / "app/assets/deliveries.csv").write_text("reference,customer_name,address,latitude,longitude,status,time_window\n" + "\n".join(f"REF-{index},Customer{index},Street{index},-33.9,151.1,pending,08:00-10:00" for index in range(30)))
        reference = self.root / "app/test/data/legacy_repository_fixture.dart"
        reference.parent.mkdir(parents=True)
        reference.write_text("accepted fixture source")
        def command(*args, **kwargs):
            if args[0] == "list": return self.inventory(args[1])
            if args[0] == "create": return UDID
            if args[0] == "get_app_container": return str(self.container)
            return ""
        with patch.object(session, "command", side_effect=command), patch.object(session, "launch", side_effect=RuntimeError("controlled failure before recovery")), patch.object(sys, "stdout", io.StringIO()):
            self.assertEqual(session.execute(), 1)
        self.assertEqual(session.report["status"], "failed")
        self.assertTrue(session.report["device_cleaned"])
        self.assertFalse(session.report["migration_fault_cleanup"]["installed"])
        self.assertEqual(session.report["fault_cleanup"]["status"], "not_applicable")
        self.assertEqual(session.report["fault_cleanup"]["user_version"], 1)
        self.assertNotIn("fault_cleanup_error", session.report)
        with closing(sqlite3.connect(self.database)) as database:
            self.assertEqual(database.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(database.execute("SELECT name FROM sqlite_master WHERE type='trigger'").fetchall(), [])
            self.assertEqual(database.execute("SELECT seq FROM outbox ORDER BY seq").fetchall(), [(7,), (11,)])

    def test_legacy_seed_rejects_symlink_sidecars_and_unapproved_shape(self):
        source = self.root / "invalid.csv"
        source.write_text("not approved source")
        output = self.root / "legacy-output"
        self.database.unlink()
        with self.assertRaises(ValueError):
            workbench.seed_legacy(self.container, UDID, "demo", source, output)
        self.assertFalse(self.database.exists())
        external = self.root / "user.sqlite"
        external.write_bytes(b"user data preserved")
        self.database.symlink_to(external)
        with self.assertRaises(ValueError):
            workbench.seed_legacy(self.container, UDID, "demo", source, output)
        self.assertEqual(external.read_bytes(), b"user data preserved")
        self.database.unlink()
        Path(str(self.database) + "-wal").write_bytes(b"existing WAL")
        with self.assertRaises(ValueError):
            workbench.seed_legacy(self.container, UDID, "demo", source, output)
        self.assertFalse(self.database.exists())

    def test_fixed_prelaunch_config_is_private_atomic_and_bound_to_each_session(self):
        self.database.unlink()
        (self.container / "Documents").rmdir()
        fixture = self.launch_fixture()
        receipt = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        path = Path(receipt["path"])
        self.assertEqual(path, self.container / "Documents" / workbench.LAUNCH_CONFIG)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(receipt["sha256"], workbench.digest(path))
        self.assertEqual(receipt["byte_length"], path.stat().st_size)
        self.assertNotIn(fixture.token, json.dumps(receipt))
        self.assertEqual(workbench.verify_launch_config(self.container, UDID, receipt), receipt)
        replacement = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, "a" * 48, fixture, receipt)
        self.assertNotEqual(replacement["sha256"], receipt["sha256"])
        self.assertEqual(list(path.parent.glob(".*.tmp")), [])
        with patch.object(workbench.os, "replace", side_effect=OSError("controlled atomic write failure")), self.assertRaises(OSError):
            workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, "c" * 48, fixture, replacement)
        self.assertEqual(workbench.verify_launch_config(self.container, UDID, replacement), replacement)
        self.assertEqual(list(path.parent.glob(".*.tmp")), [])
        with self.assertRaises(ValueError):
            workbench.verify_launch_config(self.container, UDID, receipt)
        with self.assertRaises(ValueError):
            workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, "c" * 48, fixture)
        for mode, candidate, nonce in (("local-client", CANDIDATE, "c" * 48), ("demo", "0" * 64, "c" * 48), ("demo", CANDIDATE, "a" * 48)):
            with self.subTest(mode=mode, candidate=candidate, nonce=nonce), self.assertRaises(ValueError):
                workbench.write_launch_config(self.container, UDID, mode, candidate, nonce, fixture, replacement)
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            workbench.verify_launch_config(self.container, UDID, replacement)

    def test_launch_config_missing_stale_fields_duplicates_and_foreign_urls_reject(self):
        fixture = self.launch_fixture()
        receipt = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        path = Path(receipt["path"])
        baseline = json.loads(path.read_text())
        invalid = [
            {**baseline, "schema": True}, {**baseline, "extra": "unexpected"},
            {key: value for key, value in baseline.items() if key != "syncUrl"},
            {**baseline, "candidate": "0" * 64}, {**baseline, "session": "c" * 48},
            {**baseline, "mode": "local-client"}, {**baseline, "tileUrl": "http://public.example/tiles/{z}/{x}/{y}.png"},
            {**baseline, "tileUrl": fixture.url + "/tiles/{z}/{x}/{y}.png?download=1"},
            {**baseline, "syncUrl": "http://127.0.0.1:9999/sync?token=" + fixture.token},
            {**baseline, "syncUrl": fixture.url + "/sync?token=" + fixture.token + "&token=extra"},
        ]
        for value in invalid:
            with self.subTest(value=value):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    workbench.verify_launch_config(self.container, UDID, receipt)
        for raw in ("", "{", " " * 16385, json.dumps(baseline)[:-1] + ',"schema":1}'):
            path.write_text(raw)
            with self.assertRaises(ValueError):
                workbench.verify_launch_config(self.container, UDID, receipt)
        path.write_text(json.dumps(baseline, indent=2))
        with self.assertRaises(ValueError):
            workbench.verify_launch_config(self.container, UDID, receipt)
        with self.assertRaises(ValueError):
            workbench.validate_launch_config({**baseline, "mode": "local-client"}, "local-client", CANDIDATE, SESSION)

    def test_launch_config_symlinks_and_wrong_task_container_preserve_user_files(self):
        fixture = self.launch_fixture()
        user_file = self.root / "user-config.json"
        user_file.write_bytes(b"user configuration")
        path = self.container / "Documents" / workbench.LAUNCH_CONFIG
        path.symlink_to(user_file)
        for action in (lambda: workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture),
                       lambda: workbench.read_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION)):
            with self.assertRaises(ValueError):
                action()
        path.unlink()
        path.symlink_to(self.root / "absent.json")
        with self.assertRaises(ValueError):
            workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        path.unlink()
        with self.assertRaises(ValueError):
            workbench.write_launch_config(self.container, "other-task", "demo", CANDIDATE, SESSION, fixture)
        self.database.unlink()
        (self.container / "Documents").rmdir()
        (self.container / "Documents").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        self.assertEqual(user_file.read_bytes(), b"user configuration")
        self.assertFalse((self.root / workbench.LAUNCH_CONFIG).exists())

    def test_launch_fresh_session_and_file_only_default_unavailable_ignore_sync_environment(self):
        session = self.session("local-client")
        session.device = UDID
        fixture = self.launch_fixture()
        launches = []
        def launch(*arguments, **kwargs):
            self.assertNotIn("env", kwargs)
            if arguments[0] == "get_app_container":
                return str(self.installed_app)
            launches.append(json.loads((self.container / "Documents" / workbench.LAUNCH_CONFIG).read_text()))
            stdout = Path(arguments[1].removeprefix("--stdout="))
            stdout.write_text("The Dart VM service is listening on http://127.0.0.1:4321/auth=/\n")
            return "dev.task: 321"
        with patch.object(session, "command", side_effect=launch), patch.object(session, "start_log_reader", side_effect=lambda directory: self.fake_log_reader(session, directory)), patch.object(session, "alive", return_value=True), patch.dict(os.environ, {"SIMCTL_CHILD_OCEAN_NATIVE_SYNC_URL": "http://wrong.example"}):
            session.launch("saved", fixture)
            first = session.session
            session.stop_log_reader()
            with self.assertRaises(ValueError):
                session.launch("recovered", fixture)
            self.assertFalse((session.output / "recovered").exists())
            self.assertEqual(session.launch_config["sha256"], workbench.digest(self.container / "Documents" / workbench.LAUNCH_CONFIG))
            with patch.object(session, "alive", side_effect=[False, True, True]):
                session.launch("recovered", fixture)
            self.assertNotEqual(session.session, first)
            session.stop_log_reader()
        self.assertTrue(all(value["syncUrl"] is None for value in launches))
        self.assertEqual(launches[0]["mode"], "local-client")
        self.assertEqual(launches[0]["tileUrl"], fixture.url + "/tiles/{z}/{x}/{y}.png")
        self.assertEqual(session.report["launches"][0]["session"], first)
        self.assertEqual(session.report["launches"][0]["launch_config"]["session"], first)
        self.assertNotEqual(session.report["launches"][0]["launch_config"]["sha256"], session.report["launches"][1]["launch_config"]["sha256"])

    def test_vm_publication_and_old_process_exit_deadlines_fail(self):
        session = self.session()
        session.device = UDID
        fixture = self.launch_fixture()
        with patch.object(session, "command", side_effect=lambda *args, **kwargs: str(self.installed_app) if args[0] == "get_app_container" else "dev.task: 321"), patch.object(session, "start_log_reader", side_effect=lambda directory: self.fake_log_reader(session, directory)), patch.object(session, "alive", return_value=True), patch.object(workbench.time, "monotonic", side_effect=[0, 46]):
            with self.assertRaises(TimeoutError):
                session.launch("saved", fixture)
        session.stop_log_reader()
        with patch.object(session, "command"), patch.object(session, "alive", return_value=True), patch.object(workbench.time, "monotonic", side_effect=[0, 11]):
            with self.assertRaises(TimeoutError):
                session.terminate(321)

    def test_driver_timeout_inherits_descriptors_and_reaps_without_acceptance(self):
        session = self.session()
        session.session = SESSION
        session.device = UDID
        (session.output / "saved").mkdir()
        fixture = self.launch_fixture()
        session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        class Process:
            returncode = None
            terminated = False
            timeouts = []
            def wait(self, timeout):
                self.timeouts.append(timeout)
                if not self.terminated:
                    raise subprocess.TimeoutExpired("dart driver", timeout)
                self.returncode = -15
                return -15
            def poll(self):
                return self.returncode
            def terminate(self):
                self.terminated = True
        child = Process()
        with patch.object(workbench.subprocess, "Popen", return_value=child) as spawn:
            with self.assertRaises(subprocess.TimeoutExpired):
                session.drive("saved", 321, "http://127.0.0.1:4321/auth=/", fixture)
        self.assertEqual(spawn.call_args.kwargs["pass_fds"], (51, 52))
        self.assertTrue(child.terminated)
        self.assertEqual(child.timeouts, [180, 5])
        self.assertEqual(child.returncode, -15)
        self.assertIsNone(session.driver_process)
        self.assertEqual(session.report["status"], "failed")
        self.assertNotIn("auth=/", json.dumps(session.report["commands"]))

    def test_independent_driver_forwards_frozen_scenario_and_only_its_extended_deadline(self):
        session = self.session(scenario="N5", driver_target="integration_test/acceptance_driver.dart", cold_fixture="viewport-corrupt", initial_tiles="503")
        session.session, session.device = SESSION, UDID
        (session.output / "saved").mkdir()
        fixture = self.launch_fixture()
        session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        class Process:
            returncode = 0
            def wait(self, timeout):
                self.timeout = timeout
                return 0
            def poll(self):
                return 0
        child = Process()
        with patch.object(workbench.subprocess, "Popen", return_value=child) as spawn, patch.object(workbench, "validate_driver_result", return_value=({}, {})) as validate:
            session.drive("saved", 321, "http://127.0.0.1:4321/auth=/", fixture)
        self.assertEqual(child.timeout, 330)
        argv = spawn.call_args.args[0]
        for flag, value in (("--scenario", "N5"), ("--content-size", "large"), ("--initial-tiles", "503"), ("--cold-fixture", "viewport-corrupt")):
            self.assertEqual(argv[argv.index(flag) + 1], value)
        self.assertEqual(spawn.call_args.kwargs["pass_fds"], (51, 52))
        self.assertEqual(validate.call_args.args[-1], "N5")

    def test_modified_launch_config_blocks_driver_before_child_spawn(self):
        session = self.session()
        session.session, session.device = SESSION, UDID
        fixture = self.launch_fixture()
        session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
        path = Path(session.launch_config["path"])
        path.write_bytes(path.read_bytes() + b" ")
        with patch.object(workbench.subprocess, "Popen") as spawn, self.assertRaises(ValueError):
            session.drive("saved", 321, "http://127.0.0.1:4321/auth=/", fixture)
        spawn.assert_not_called()

    def test_boot_failure_still_cleans_only_created_udid_and_retains_raw_exit(self):
        session = self.session()
        calls = []
        def simctl(argv, **kwargs):
            calls.append((argv, kwargs))
            action = argv[2]
            if action == "list":
                return subprocess.CompletedProcess(argv, 0, self.inventory(argv[3]), "")
            return subprocess.CompletedProcess(argv, 1 if action == "boot" else 0, UDID if action == "create" else "", "controlled boot failure" if action == "boot" else "")
        with patch.object(workbench.subprocess, "run", side_effect=simctl), patch.object(workbench.os, "kill"), patch("sys.stdout", io.StringIO()):
            self.assertEqual(session.execute(), 1)
        self.assertEqual([argv[2] for argv, kwargs in calls], ["list", "list", "create", "boot", "shutdown", "delete"])
        self.assertTrue(all(argv[3] == UDID for argv, kwargs in calls[3:]))
        self.assertTrue(all(kwargs["pass_fds"] == (51, 52) for argv, kwargs in calls))
        report = json.loads((session.output / "result.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["business_acceptance"])
        self.assertTrue(report["device_cleaned"])
        self.assertEqual(report["commands"][3]["exit_code"], 1)

    def test_private_driver_and_fixed_build_preserve_public_entrypoint_boundary(self):
        directory = self.root / "app/integration_test"
        directory.mkdir(parents=True)
        (directory / "independent.dart").write_text("void main() {}")
        self.assertEqual(workbench.driver_target(self.root, "integration_test/independent.dart"), "integration_test/independent.dart")
        for name in ("../outside.dart", "integration_test/missing.dart", "integration_test", "lib/main.dart"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                workbench.driver_target(self.root, name)
        outside = self.root / "outside.dart"
        outside.write_text("external")
        (directory / "escape.dart").symlink_to(outside)
        with self.assertRaises(ValueError):
            workbench.driver_target(self.root, "integration_test/escape.dart")
        options = {"configuration": "demo", "build_mode": "debug", "ios_target": "simulator", "scope": "workbench", "entrypoint": "lib/main.dart", "driver_target": "integration_test/independent.dart"}
        plan = run.stages("native", self.root / "run", "candidate", options=options, root=self.root)
        self.assertEqual(plan[-2][0], "workbench-build")
        self.assertIn(workbench.ENTRY, plan[-2][1])
        self.assertIn("integration_test/independent.dart", plan[-1][1])
        self.assertNotIn("--driver-target", run.build_arguments(options))
        for scope, entry in (("probe", "lib/harness_probe.dart"), ("startup", "lib/main.dart")):
            existing = run.stages("native", self.root / "run", "candidate", options={**options, "scope": scope}, root=self.root)
            self.assertIn(entry, existing[-2][1])
            self.assertNotIn("--driver-target", existing[-1][1])
            if scope == "startup":
                self.assertIn("--dart-define=OCEAN_TILE_URL=" + run.STARTUP_TILES, existing[-2][1])
        self.assertFalse(any("OCEAN_TILE_URL=" in item for item in run.build_arguments(options)))

    def test_container_database_modes_and_symlink_escape_reject(self):
        self.assertEqual(workbench.owned_container(self.container, UDID), self.container)
        with self.assertRaises(ValueError):
            workbench.owned_container(self.container, "different-task")
        with self.assertRaises(ValueError):
            workbench.owned_container(self.root, UDID)
        self.assertEqual(workbench.database_path(self.container, "demo"), self.database)
        with self.assertRaises(FileNotFoundError):
            workbench.database_path(self.container, "local-client")
        external = self.root / "user.sqlite"
        external.write_bytes(self.database.read_bytes())
        self.database.unlink()
        self.database.symlink_to(external)
        with self.assertRaises(ValueError):
            workbench.database_path(self.container, "demo")

    def test_ack_failure_rolls_back_durable_confirmation_and_removes_only_own_triggers(self):
        with closing(sqlite3.connect(self.database)) as database:
            database.execute("CREATE TRIGGER unrelated AFTER INSERT ON datasets BEGIN SELECT 1; END")
        workbench.sql_fault(self.container, "demo", "ack")
        with closing(sqlite3.connect(self.database)) as database:
            with self.assertRaises(sqlite3.IntegrityError), database:
                database.execute("UPDATE stops SET acknowledged_at=123 WHERE id='stop'")
                database.execute("DELETE FROM outbox WHERE seq=7")
            self.assertIsNone(database.execute("SELECT acknowledged_at FROM stops").fetchone()[0])
            self.assertEqual(database.execute("SELECT count(*) FROM outbox").fetchone()[0], 1)
        workbench.sql_fault(self.container, "demo", "none")
        with closing(sqlite3.connect(self.database)) as database, database:
            self.assertEqual(database.execute("SELECT name FROM sqlite_master WHERE type='trigger'").fetchall(), [("unrelated",)])
            database.execute("UPDATE stops SET acknowledged_at=123 WHERE id='stop'")
            database.execute("DELETE FROM outbox WHERE seq=7")
        with self.assertRaises(ValueError):
            workbench.sql_fault(self.container, "demo", "arbitrary SQL")

    def test_submit_settings_faults_and_wrong_schema_fail_closed(self):
        for fault, statement in (("submit", "INSERT INTO outbox VALUES(11,'next','batch','stop')"), ("settings", "UPDATE delivery_settings SET online=1")):
            with self.subTest(fault=fault):
                workbench.sql_fault(self.container, "demo", fault)
                with closing(sqlite3.connect(self.database)) as database:
                    with self.assertRaises(sqlite3.IntegrityError), database:
                        database.execute(statement)
                    self.assertEqual(database.execute("SELECT online FROM delivery_settings").fetchone()[0], 0)
                    self.assertEqual(database.execute("SELECT seq FROM outbox").fetchall(), [(7,)])
        with closing(sqlite3.connect(self.database)) as database:
            database.execute("PRAGMA user_version=1")
        with self.assertRaises(ValueError):
            workbench.sql_fault(self.container, "demo", "none")

    def test_backup_retains_committed_wal_and_identities_without_changing_source(self):
        destination = self.root / "backup.sqlite"
        with closing(sqlite3.connect(self.database)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("INSERT INTO outbox VALUES(11,'second','batch','stop')")
            writer.commit()
            self.assertTrue(Path(str(self.database) + "-wal").stat().st_size > 0)
            snapshot = workbench.sqlite_snapshot(self.container, "demo", destination)
        self.assertEqual(workbench.outbox_identities(snapshot["tables"]["outbox"]), [(7, "stable", "batch", "stop"), (11, "second", "batch", "stop")])
        self.assertEqual(snapshot["sha256"], workbench.digest(destination))
        with patch.object(workbench.time, "monotonic", side_effect=[0, 6]):
            with self.assertRaises(TimeoutError):
                workbench.sqlite_snapshot(self.container, "demo", self.root / "timeout.sqlite")

    def driver_journal_fixture(self):
        output = self.root / "bounded-driver"
        output.mkdir()
        launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, self.launch_fixture())
        expected = {"schema": 1, "processId": 321, "candidate": CANDIDATE, "configuration": "demo", "session": SESSION,
                    "launchConfigPath": launch_config["path"], "launchConfigByteLength": launch_config["byte_length"], "launchConfigSchema": 1}
        action = {**expected, "action": "actual-ui", "vmProcessId": 321}
        snapshot = {**expected, "mode": "demo", "transport": "controlled-http-simulated", "databasePath": str(self.database), "outbox": []}
        workbench.write_json(output / "result.json", {**expected, "status": "passed", "phase": "saved", "vmProcessId": 321})
        for name in ("snapshot.json", "initial-snapshot.json"):
            workbench.write_json(output / name, snapshot)
        for name, row in (("actions.jsonl", action), ("observations.jsonl", snapshot)):
            (output / name).write_text(json.dumps(row) + "\n")
        return output, launch_config, action, snapshot

    @staticmethod
    def write_driver_journal_bytes(file, row, size):
        # Complete JSON with an ASCII payload gives an exact byte boundary;
        # the validator still parses the entire row and checks its identity.
        empty = json.dumps({**row, "padding": ""}).encode() + b"\n"
        padding = size - len(empty)
        if padding < 0:
            raise ValueError("journal fixture is smaller than its complete JSON row")
        file.write_bytes(json.dumps({**row, "padding": "x" * padding}).encode() + b"\n")

    def test_full_observation_journal_above_eight_mib_and_at_sixteen_mib_is_accepted(self):
        output, launch_config, _, snapshot = self.driver_journal_fixture()
        for size in (9 * 1024 * 1024, 16 * 1024 * 1024):
            with self.subTest(bytes=size):
                self.write_driver_journal_bytes(output / "observations.jsonl", snapshot, size)
                result, observed = workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config)
                self.assertEqual(result["status"], "passed")
                self.assertEqual(observed, snapshot)

    def test_observation_journal_over_sixteen_mib_is_rejected(self):
        output, launch_config, _, snapshot = self.driver_journal_fixture()
        self.write_driver_journal_bytes(output / "observations.jsonl", snapshot, 16 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, "journal missing, empty or outside bounds"):
            workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config)

    def test_action_journal_keeps_its_eight_mib_boundary(self):
        output, launch_config, action, _ = self.driver_journal_fixture()
        self.write_driver_journal_bytes(output / "actions.jsonl", action, 8 * 1024 * 1024)
        self.assertEqual(workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config)[0]["status"], "passed")
        self.write_driver_journal_bytes(output / "actions.jsonl", action, 8 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, "journal missing, empty or outside bounds"):
            workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config)

    def test_larger_observation_journal_still_parses_and_checks_every_row(self):
        output, launch_config, _, snapshot = self.driver_journal_fixture()
        for row, error in (({**snapshot, "processId": 320}, ValueError),
                           ({**snapshot, "processId": True}, ValueError),
                           ({**snapshot, "launchConfigByteLength": 1}, ValueError),
                           ("truncated-json", json.JSONDecodeError)):
            with self.subTest(row=row):
                self.write_driver_journal_bytes(output / "observations.jsonl", snapshot, 9 * 1024 * 1024)
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row) + "\n" if isinstance(row, dict) else '{"processId":\n')
                with self.assertRaises(error):
                    workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config)

    def test_stale_candidate_pid_vm_session_and_database_receipts_reject(self):
        output = self.root / "driver"
        output.mkdir()
        launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, self.launch_fixture())
        expected = {"schema": 1, "processId": 321, "candidate": CANDIDATE, "configuration": "demo", "session": SESSION,
                    "launchConfigPath": launch_config["path"], "launchConfigByteLength": launch_config["byte_length"], "launchConfigSchema": 1}
        result = {**expected, "status": "passed", "phase": "saved", "vmProcessId": 321}
        snapshot = {**expected, "mode": "demo", "transport": "controlled-http-simulated", "databasePath": str(self.database), "outbox": [{"seq": 7, "operationId": "stable", "datasetId": "batch", "stopId": "stop"}]}
        (output / "actions.jsonl").write_text(json.dumps({**expected, "action": "actual-ui", "vmProcessId": 321}) + "\n")
        (output / "observations.jsonl").write_text(json.dumps(snapshot) + "\n")
        workbench.write_json(output / "initial-snapshot.json", snapshot)
        def validate(receipt=result, observation=snapshot, scenario=None):
            workbench.write_json(output / "result.json", receipt)
            workbench.write_json(output / "snapshot.json", observation)
            return workbench.validate_driver_result(output, "saved", 321, CANDIDATE, "demo", SESSION, self.container, launch_config, scenario)
        self.assertEqual(validate()[0], result)
        acceptance = {**result, "scope": "e08-native-functional-acceptance", "scenario": "N5"}
        self.assertEqual(validate(receipt=acceptance, scenario="N5")[0], acceptance)
        for receipt in (result, {**acceptance, "scope": "x02-tooling-smoke"}, {**acceptance, "scenario": "N4"}):
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                validate(receipt=receipt, scenario="N5")
        for key, value in (("candidate", "old"), ("processId", 320), ("processId", True), ("configuration", "local-client"), ("session", "old-session"), ("launchConfigPath", str(self.root / "user-config.json")), ("launchConfigByteLength", 1), ("launchConfigByteLength", True), ("launchConfigSchema", True)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate(observation={**snapshot, key: value})
        for value in (320, True, None):
            with self.subTest(vm=value), self.assertRaises(ValueError):
                validate(receipt={**result, "vmProcessId": value})
        for value in ("failed", "not_run"):
            with self.subTest(status=value), self.assertRaises(ValueError):
                validate(receipt={**result, "status": value})
        with self.assertRaises(ValueError):
            validate(observation={**snapshot, "databasePath": str(self.root / "user.sqlite")})
        workbench.write_json(output / "initial-snapshot.json", {**snapshot, "launchConfigPath": str(self.root / "stale.json")})
        with self.assertRaises(ValueError):
            validate()
        workbench.write_json(output / "initial-snapshot.json", snapshot)
        (output / "observations.jsonl").write_text(json.dumps({**snapshot, "launchConfigByteLength": 1}) + "\n")
        with self.assertRaises(ValueError):
            validate()

    def test_local_tiles_auth_allowlist_and_wrong_ack_are_real_http(self):
        faults = []
        with workbench.Fixture(self.root, lambda name: {"capture": name}, faults.append) as fixture:
            with self.request(fixture, "/tiles/1/0/0.png", authorized=False) as response:
                tile = response.read()
                self.assertEqual(response.status, 200)
                self.assertEqual(tile[:8], b"\x89PNG\r\n\x1a\n")
                offset = 8
                while offset < len(tile):
                    size = struct.unpack(">I", tile[offset:offset + 4])[0]
                    body = tile[offset + 4:offset + 8 + size]
                    crc = struct.unpack(">I", tile[offset + 8 + size:offset + 12 + size])[0]
                    self.assertEqual(zlib.crc32(body), crc)
                    offset += 12 + size
            for value in ({"businessMutation": "ack"}, {"delayMs": True}, {"delayMs": 15001}, {"sqlFault": "external"}):
                with self.subTest(control=value), self.assertRaises(HTTPError):
                    self.request(fixture, "/control", value)
            with self.assertRaises(HTTPError):
                self.request(fixture, "/control", {"tiles": "503"}, authorized=False)
            with self.request(fixture, "/control", {"tiles": "503", "sync": "wrong", "delayMs": 0, "sqlFault": "ack"}):
                pass
            with self.assertRaises(HTTPError) as error:
                self.request(fixture, "/tiles/1/0/0.png")
            self.assertEqual(error.exception.code, 503)
            body = {"operationId": "stable", "datasetId": "batch", "stopId": "stop"}
            with self.assertRaises(HTTPError):
                self.request(fixture, "/sync", body)
            with self.request(fixture, "/sync?token=" + fixture.token, body) as response:
                self.assertEqual(json.load(response), {**body, "operationId": "wrong-stable"})
            self.assertEqual(faults, ["ack"])
            with self.assertRaises(HTTPError):
                self.request(fixture, "/capture", {"name": "../../user"})
            with self.request(fixture, "/capture", {"name": "controlled-state"}) as response:
                self.assertEqual(json.load(response), {"capture": "controlled-state"})

    def test_parallel_tile_burst_connects_before_accept_then_serves_all_and_cleans(self):
        count = 24
        start, connected = threading.Barrier(count + 1, timeout=3), threading.Barrier(count + 1, timeout=3)
        accept = threading.Event()
        outcomes, errors, result_lock = [], [], threading.Lock()
        fixture = workbench.Fixture(self.root, lambda name: {}, lambda value: None)
        def serve():
            # Withhold accept until all clients have completed real TCP connects;
            # this exercises listen backlog, not a lucky sequence of fast GETs.
            accept.wait(timeout=5)
            fixture.server.serve_forever()
        fixture.thread = threading.Thread(target=serve, daemon=True)
        def tile(index):
            connection = HTTPConnection("127.0.0.1", fixture.server.server_port, timeout=3)
            try:
                start.wait()
                connection.connect()
                connected.wait()
                connection.request("GET", f"/tiles/11/{index}/{index}.png")
                response = connection.getresponse()
                result = (response.status, response.getheader("Content-Type"), response.read())
                with result_lock:
                    outcomes.append(result)
            except (OSError, HTTPException, threading.BrokenBarrierError) as error:
                with result_lock:
                    errors.append(type(error).__name__)
            finally:
                connection.close()
        clients = [threading.Thread(target=tile, args=(index,)) for index in range(count)]
        with fixture:
            try:
                for client in clients:
                    client.start()
                start.wait()
                connected.wait()
                accept.set()
                deadline = workbench.time.monotonic() + 5
                for client in clients:
                    client.join(timeout=max(0, deadline - workbench.time.monotonic()))
                self.assertFalse(any(client.is_alive() for client in clients))
            finally:
                accept.set()
                start.abort()
                connected.abort()
                deadline = workbench.time.monotonic() + 5
                for client in clients:
                    if client.ident is not None:
                        client.join(timeout=max(0, deadline - workbench.time.monotonic()))
        self.assertEqual(errors, [])
        self.assertEqual(outcomes, [(200, "image/png", workbench.TILE)] * count)
        tiles = [row for row in fixture.requests if row["kind"] == "tile"]
        self.assertEqual(len(tiles), count)
        self.assertEqual({row["path"] for row in tiles}, {f"/tiles/11/{index}/{index}.png" for index in range(count)})
        self.assertTrue(all(row["status"] == 200 for row in tiles))
        raw_records = [json.loads(line) for line in (self.root / "fixture-requests.jsonl").read_text().splitlines()]
        raw_tiles = [row for row in raw_records if row["kind"] == "tile"]
        self.assertEqual(raw_tiles, tiles)
        self.assertEqual(fixture.requests[0]["listenBacklog"], 64)
        self.assertTrue(fixture.requests[-1]["handlersCleaned"])
        self.assertEqual(fixture.handlers, set())
        self.assertEqual(fixture.connections, set())

    def test_exact_length_capture_named_like_phase_preserves_http_receipts(self):
        session = self.session()
        session.device, session.session, session.pid, session.active_phase = UDID, SESSION, 321, "saved"
        directory = session.output / "saved"
        directory.mkdir()
        journal = self.database.parent / workbench.JOURNAL
        journal.write_text(json.dumps({"source": "repository", "processId": 321, "candidate": CANDIDATE,
            "configuration": "demo", "session": SESSION}) + "\n")
        def screenshot(*arguments, **kwargs):
            self.assertEqual(arguments[:3], ("io", UDID, "screenshot"))
            Path(arguments[-1]).write_bytes(workbench.TILE)
        body = json.dumps({"name": "saved"}).encode()
        with workbench.Fixture(self.root, session.capture, lambda value: None) as fixture, patch.object(session, "command", side_effect=screenshot):
            session.launch_config = workbench.write_launch_config(self.container, UDID, "demo", CANDIDATE, SESSION, fixture)
            status, captured = self.framed_post(fixture, [("Content-Length", str(len(body)))], body)
            self.assertEqual(status, 200)
            self.assertEqual(workbench.outbox_identities(captured["database"]["tables"]["outbox"]), [(7, "stable", "batch", "stop")])
            self.assertEqual((directory / "saved.png").read_bytes(), workbench.TILE)
            self.assertTrue((directory / "saved.sqlite").is_file())
            self.assertTrue((directory / "saved.journal.jsonl").is_file())
            retained = {name: workbench.digest(directory / name) for name in ("saved.png", "saved.sqlite", "saved.journal.jsonl")}
            self.assertEqual(self.framed_post(fixture, [("Content-Length", str(len(body)))], body), (400, {"error": "task capture name already used"}))
            self.assertEqual(retained, {name: workbench.digest(directory / name) for name in retained})
        request = next(row for row in fixture.requests if row["kind"] == "fixture-request")
        response = next(row for row in fixture.requests if row["kind"] == "fixture-response")
        self.assertEqual(request["path"], "/capture")
        self.assertEqual(request["contentLength"], [str(len(body))])
        self.assertEqual(request["transferEncoding"], [])
        self.assertTrue(request["hostAuthorized"])
        self.assertEqual(response["requestSeq"], request["seq"])
        self.assertEqual(response["status"], 200)
        self.assertTrue(response["emitted"])
        self.assertEqual(response["captureName"], "saved")
        self.assertIsNone(response["error"])
        self.assertNotIn(fixture.token, (self.root / "fixture-requests.jsonl").read_text())

    def test_missing_chunked_ambiguous_short_and_oversized_post_framing_reject(self):
        names = []
        body = json.dumps({"name": "saved"}).encode()
        cases = [
            ([], body, False),
            ([("Transfer-Encoding", "chunked")], b"0\r\n\r\n", False),
            ([("Transfer-Encoding", "chunked"), ("Content-Length", str(len(body)))], body, False),
            ([("Content-Length", str(len(body))), ("Content-Length", str(len(body)))], body, False),
            ([("Content-Length", "0")], b"", False),
            ([("Content-Length", "-1")], body, False),
            ([("Content-Length", "+1")], body, False),
            ([("Content-Length", "65537")], b"", False),
            ([("Content-Length", "20")], b"{}", True),
        ]
        with workbench.Fixture(self.root, names.append, lambda value: None) as fixture:
            for headers, raw, short in cases:
                with self.subTest(headers=headers):
                    status, receipt = self.framed_post(fixture, headers, raw, short)
                    self.assertEqual(status, 400)
                    self.assertTrue(receipt["error"])
        self.assertEqual(names, [])
        requests = [row for row in fixture.requests if row["kind"] == "fixture-request"]
        responses = [row for row in fixture.requests if row["kind"] == "fixture-response"]
        self.assertEqual(len(requests), len(cases))
        self.assertEqual({row["requestSeq"] for row in responses}, {row["seq"] for row in requests})
        self.assertTrue(all(row["status"] == 400 and row["error"]["type"] == "ValueError" for row in responses))
        self.assertTrue(all(row["captureName"] is None for row in responses))
        self.assertNotIn(fixture.token, (self.root / "fixture-requests.jsonl").read_text())

    def test_capture_callback_error_is_bounded_secretfiltered_and_retained(self):
        def capture(name):
            raise RuntimeError("actual capture fault " + fixture.token + " other?token=sensitive-value " + "x" * 2048)
        with workbench.Fixture(self.root, capture, lambda value: None) as fixture:
            body = json.dumps({"name": "saved"}).encode()
            status, receipt = self.framed_post(fixture, [("Content-Length", str(len(body)))], body)
            self.assertEqual(status, 400)
        response = next(row for row in fixture.requests if row["kind"] == "fixture-response")
        self.assertEqual(response["captureName"], "saved")
        self.assertEqual(response["error"]["type"], "RuntimeError")
        self.assertEqual(receipt["error"], response["error"]["message"])
        self.assertEqual(len(response["error"]["message"]), 1024)
        raw = (self.root / "fixture-requests.jsonl").read_text()
        self.assertNotIn(fixture.token, raw)
        self.assertNotIn("sensitive-value", raw)
        self.assertIn("@task-secret", raw)

    def test_held_matching_ack_releases_without_replacing_request_identity(self):
        outcome = []
        with workbench.Fixture(self.root, lambda name: {}, lambda value: None) as fixture:
            fixture.control({"sync": "hold", "delayMs": 0})
            body = {"operationId": "stable", "datasetId": "batch", "stopId": "stop"}
            def send():
                with self.request(fixture, "/sync?token=" + fixture.token, body) as response:
                    outcome.append(json.load(response))
            thread = threading.Thread(target=send)
            thread.start()
            try:
                self.assertTrue(fixture.sync_received.wait(timeout=2))
                self.assertEqual(outcome, [])
                fixture.control({"sync": "match"})
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertEqual(outcome, [body])
            finally:
                fixture.stopping.set()
                thread.join(timeout=3)

    def test_never_request_cleanup_finishes_handlers_without_emitting_ack(self):
        outcome = []
        fixture = workbench.Fixture(self.root, lambda name: {}, lambda value: None)
        with fixture:
            fixture.control({"sync": "never", "delayMs": 0})
            body = {"operationId": "stable", "datasetId": "batch", "stopId": "stop"}
            def send():
                try:
                    with self.request(fixture, "/sync?token=" + fixture.token, body) as response:
                        outcome.append(json.load(response))
                except (OSError, HTTPException) as error:
                    outcome.append(type(error).__name__)
            thread = threading.Thread(target=send)
            thread.start()
            self.assertTrue(fixture.sync_received.wait(timeout=2))
            self.assertEqual(fixture.active_sync, 1)
            self.assertEqual(outcome, [])
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(fixture.active_sync, 0)
        self.assertEqual(fixture.max_active_sync, 1)
        self.assertFalse(any(record["kind"] == "sync-response" for record in fixture.requests))
        self.assertTrue(fixture.requests[-1]["handlersCleaned"])
        self.assertTrue(any(record.get("completion") == "cleanup_closed_without_ack" for record in fixture.requests))


if __name__ == "__main__":
    unittest.main()
