import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from harness.gate import CAPABILITIES, EvidenceError, GATES, SOURCE_ROOT, Validator, evaluate, evaluate_local


class GateTests(unittest.TestCase):
    """Synthetic reports validate gate rejection logic, not product readiness."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fingerprint = "a" * 64
        self.manifest = {
            "candidate": {"source_fingerprint": self.fingerprint},
            "enforcement_deployed": True,
            "service_mode": "connected",
            "harness": {}, "gates": {},
        }
        for group, ids, status in (
            ("harness", CAPABILITIES, "demonstrated"), ("gates", GATES, "passed"),
        ):
            for entry_id in ids:
                self.manifest[group][entry_id] = {
                    "status": status, "candidate": self.fingerprint,
                    "evidence": [self.evidence(f"{entry_id}.log", "raw-log", f"synthetic {entry_id} fixture\n")],
                }
        for entry_id, kind, fields in (
            ("H06", "ci-enforcement", {"enforced": True}),
            ("H06", "release-enforcement", {"enforced": True}),
            ("G2", "native-acceptance", {"platform": "ios", "process_restart": True}),
            ("G3", "performance", {"device_type": "real", "build_mode": "profile"}),
            ("G4", "connected-service", {"transport": "connected"}),
        ):
            self.add_report(entry_id, kind, fields)
        self.quality = {
            "command": "quality",
            "candidate": {"source_fingerprint": self.fingerprint},
            "candidate_after": {"source_fingerprint": self.fingerprint},
            "execution_candidate_after": {"source_fingerprint": self.fingerprint},
            "started_at": "2026-10-10T10:00:00+00:00",
            "finished_at": "2026-10-10T10:01:00+00:00",
            "execution_root": str(self.root / "execution"),
            "source_root": str(SOURCE_ROOT),
            "options": {"configuration": "local-client", "targets": []},
            "isolation": {"requested": True, "task_owned": True, "cleaned": True, "verified_fingerprint": self.fingerprint},
            "lease": {"status": "released"},
            "inputs": {"flutter": json.loads((SOURCE_ROOT / "app/.fvmrc").read_text())["flutter"], "lock_sha256": hashlib.sha256((SOURCE_ROOT / "app/pubspec.lock").read_bytes()).hexdigest(), "asset_sha256": hashlib.sha256((SOURCE_ROOT / "app/assets/deliveries.csv").read_bytes()).hexdigest()},
            "stage_spec": [],
            "job": {"status": "passed"},
            "stages": [],
        }
        commands = {
            "repository": ["python3", "harness/run.py", "_check"],
            "tooling-tests": ["python3", "-m", "unittest", "discover", "-s", "harness/tests", "-v"],
            "sdk": ["python3", "harness/run.py", "_sdk"],
            "pub": ["flutter", "pub", "get", "--enforce-lockfile"],
            "format": ["dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test", "integration_test"],
            "analyze": ["flutter", "analyze", "--no-pub"],
            "flutter-tests": ["flutter", "test", "--no-pub", "--reporter", "expanded", "--dart-define=OCEAN_MODE=local-client"],
        }
        for stage_id, command in commands.items():
            text = "synthetic passed stage\n"
            if stage_id == "tooling-tests":
                text = "".join(f"test_case_{i} (fixture.SyntheticTests.test_case_{i}) ... ok\n" for i in range(9)) + "\n----------------------------------------------------------------------\nRan 9 tests in 0.02s\n\nOK\n"
            if stage_id == "flutter-tests":
                text = "00:01 +9: All tests passed!\n"
            log = self.evidence(f"quality-{stage_id}.log", "raw-log", text)
            cwd = self.quality["execution_root"] + ("/app" if stage_id in ("pub", "format", "analyze", "flutter-tests") else "")
            completion = {"spawned": True, "wrapper_pid": 99, "process_group": 99, "wrapper_reaped": True,
                          "returncode": 0, "group_alive": False, "cleanup_errors": []}
            self.quality["stages"].append({"id": stage_id, "status": "passed", "exit_code": 0, "job_pid": 99, "command": command, "cwd": cwd, "log_path": log["path"], "sha256": log["sha256"], "completion": completion})
            self.quality["stage_spec"].append({"id": stage_id, "command": command, "cwd": cwd.replace(self.quality["execution_root"], "@workspace")})
        self.entry("G1")["evidence"].append(self.evidence("quality.json", "quality-run", json.dumps(self.quality)))
        artifact = self.evidence("release.bin", "release-artifact", b"synthetic release artifact")
        self.manifest["gates"]["G5"]["evidence"].append(artifact)
        self.add_report("G5", "release-signature", {
            "build_mode": "release", "signed": True, "signing_kind": "production",
            "artifact_sha256": artifact["sha256"],
        })
        self.add_report("G6", "authorization-receipt", {"authorized": True, "destination": "synthetic://test"})
        self.add_report("G6", "delivery-receipt", {
            "delivered": True, "destination": "synthetic://test", "artifact_sha256": artifact["sha256"],
        })

    def tearDown(self):
        self.temp.cleanup()

    def evidence(self, name, kind, value):
        raw = value.encode() if isinstance(value, str) else value
        (self.root / name).write_bytes(raw)
        return {"path": name, "kind": kind, "sha256": hashlib.sha256(raw).hexdigest()}

    def entry(self, entry_id):
        group = "harness" if entry_id.startswith("H") else "gates"
        return self.manifest[group][entry_id]

    def add_report(self, entry_id, kind, fields):
        report = {"candidate": self.fingerprint, "status": "passed", **fields}
        item = self.evidence(f"{kind}.json", kind, json.dumps(report))
        self.entry(entry_id)["evidence"].append(item)

    def change_report(self, entry_id, kind, changes):
        item = next(value for value in self.entry(entry_id)["evidence"] if value["kind"] == kind)
        path = self.root / item["path"]
        report = json.loads(path.read_bytes())
        report.update(changes)
        raw = json.dumps(report).encode()
        path.write_bytes(raw)
        item["sha256"] = hashlib.sha256(raw).hexdigest()

    def assert_rejected(self, reason, manifest=None, fingerprint=None):
        result = evaluate(manifest or self.manifest, fingerprint or self.fingerprint, self.root)
        self.assertFalse(result["allowed"], result)
        self.assertTrue(any(reason in value for value in result["reasons"]), result)
        return result

    def settings_snapshot(self, name, rows=(), datasets=("dataset-fixture",)):
        """Read genuine SQLite through the immutable evidence reader."""
        path = self.root / (name + ".sqlite")
        with sqlite3.connect(path) as connection:
            connection.executescript("""
                PRAGMA user_version=2;
                CREATE TABLE datasets (id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE stops (
                    id TEXT PRIMARY KEY NOT NULL,
                    dataset_id TEXT NOT NULL REFERENCES datasets(id),
                    reference TEXT NOT NULL, customer_name TEXT NOT NULL,
                    address TEXT NOT NULL, latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('pending','completed','failed')),
                    reason TEXT, time_window TEXT, note TEXT,
                    recorded_at INTEGER, operation_id TEXT UNIQUE,
                    acknowledged_at INTEGER,
                    UNIQUE(dataset_id,reference), UNIQUE(dataset_id,id)
                );
                CREATE TABLE outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL UNIQUE, dataset_id TEXT NOT NULL,
                    stop_id TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('completed','failed')),
                    reason TEXT, note TEXT, recorded_at INTEGER,
                    FOREIGN KEY(dataset_id,stop_id) REFERENCES stops(dataset_id,id)
                );
                CREATE TABLE delivery_settings (
                    dataset_id TEXT PRIMARY KEY NOT NULL REFERENCES datasets(id),
                    online INTEGER NOT NULL DEFAULT 1 CHECK (online IN (0,1)),
                    viewport_latitude REAL, viewport_longitude REAL, viewport_zoom REAL
                );
            """)
            connection.executemany("INSERT INTO datasets VALUES (?)", [(value,) for value in datasets])
            connection.execute("""
                INSERT INTO stops (id,dataset_id,reference,customer_name,address,
                                   latitude,longitude,status,time_window)
                VALUES ('stop-fixture','dataset-fixture','fixture-ref','Fixture',
                        'Fixture address',-33.87,151.21,'pending','09:00–12:00')
            """)
            connection.executemany("INSERT INTO delivery_settings VALUES (?,?,?,?,?)", rows)
        raw = path.read_bytes()
        validator = Validator(self.manifest, self.fingerprint, self.root)
        item = validator.raw({"path": path.name, "kind": "sqlite-backup", "sha256": hashlib.sha256(raw).hexdigest()})
        database = validator.database(item)
        snapshot = {
            "outbox": [],
            "persistedStops": [{"id": "stop-fixture", "status": "pending", "reason": None,
                                "note": None, "operationId": None, "recordedAt": None,
                                "acknowledgedAt": None, "timeWindow": "09:00–12:00"}],
            "persistedSettings": {"datasetId": "dataset-fixture", "online": True, "viewport": None},
        }
        self.assertEqual(path.read_bytes(), raw)
        return validator, snapshot, database

    def test_empty_settings_accept_only_current_sql_dataset_canonical_defaults(self):
        validator, snapshot, database = self.settings_snapshot("default-settings")
        self.assertEqual(database["tables"]["delivery_settings"], [])
        validator.snapshot_database(snapshot, database)
        for field, value in (
            ("online", False), ("online", 1),
            ("datasetId", "forged-dataset"),
            ("viewport", {"datasetId": "dataset-fixture", "latitude": -33.87,
                          "longitude": 151.21, "zoom": 15.0}),
        ):
            with self.subTest(field=field, value=value):
                forged = copy.deepcopy(snapshot)
                forged["persistedSettings"][field] = value
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)

    def test_settings_require_unambiguous_actual_dataset_and_at_most_one_row(self):
        for name, datasets, rows, message in (
            ("missing-dataset", (), (), "actual SQLite datasets"),
            ("multiple-datasets", ("dataset-fixture", "other"), (), "exactly one current SQLite dataset"),
            ("multiple-settings", ("dataset-fixture",),
             (("dataset-fixture", 1, None, None, None), ("other", 0, None, None, None)),
             "at most one persisted dataset settings row"),
            ("foreign-settings", ("dataset-fixture",), (("other", 1, None, None, None),),
             "persisted settings current SQLite dataset"),
        ):
            with self.subTest(name=name):
                validator, snapshot, database = self.settings_snapshot(name, rows, datasets)
                with self.assertRaisesRegex(EvidenceError, message):
                    validator.snapshot_database(snapshot, database)

    def test_persisted_settings_retain_online_and_validated_viewport_rules(self):
        for index, (online, coordinates, viewport) in enumerate((
            (0, (None, None, None), None),
            (1, (-33.87, 151.21, 15.0), {"datasetId": "dataset-fixture", "latitude": -33.87,
                                       "longitude": 151.21, "zoom": 15.0}),
            (0, (100.0, 151.21, 15.0), None),
            (1, (-33.87, 151.21, 23.0), None),
            (1, (-33.87, None, 15.0), None),
            (1, (float("inf"), 151.21, 15.0), None),
        )):
            with self.subTest(online=online, coordinates=coordinates):
                row = ("dataset-fixture", online, *coordinates)
                validator, snapshot, database = self.settings_snapshot("persisted-settings-" + str(index), (row,))
                snapshot["persistedSettings"].update(online=bool(online), viewport=viewport)
                validator.snapshot_database(snapshot, database)
                forged = copy.deepcopy(snapshot)
                forged["persistedSettings"]["online"] = not bool(online)
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)
                forged["persistedSettings"]["online"] = bool(online)
                forged["persistedSettings"]["viewport"] = None if viewport is not None else {
                    "datasetId": "dataset-fixture", "latitude": -33.87,
                    "longitude": 151.21, "zoom": 15.0,
                }
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)

    def saved_phase_fixture(self):
        count = getattr(self, "phase_fixture_count", 0)
        self.phase_fixture_count = count + 1
        prefix = "phase-fixture-" + str(count)
        validator, snapshot, _ = self.settings_snapshot(prefix, (("dataset-fixture", 0, -33.87, 151.21, 16.0),))
        sql_path = self.root / (prefix + ".sqlite")
        with sqlite3.connect(sql_path) as connection:
            connection.execute("UPDATE stops SET status='completed',operation_id='operation-fixture',recorded_at=1700000000000")
            connection.execute("INSERT INTO outbox VALUES (7,'operation-fixture','dataset-fixture','stop-fixture','completed',NULL,NULL,1700000000000)")
        owner = self.root / (prefix + "-native")
        (owner / "saved").mkdir(parents=True)
        refs = []
        def artifact(name, kind, value):
            if isinstance(value, (dict, list)):
                value = json.dumps(value)
            ref = self.evidence(owner.name + "/" + name, kind, value)
            original = {**ref, "path": name, "candidate": self.fingerprint}
            refs.append(original)
            return validator.raw(original, owner)
        sql = artifact("saved/phase-final.sqlite", "sqlite-backup", sql_path.read_bytes())
        database = validator.database(sql)
        container = str(self.root / "installation")
        launches = []
        for phase, pid in (("saved", 101), ("recovered", 102), ("confirmed", 103)):
            launches.append({"phase": phase, "processId": pid, "session": "session-" + phase,
                             "candidate": self.fingerprint, "configuration": "demo",
                             "launch_config": {"path": container + "/Documents/native-workbench-launch.json",
                                               "byte_length": 321, "schema": 1}})
        launch = launches[0]
        snapshot.update({key: launch[key] for key in ("processId", "session", "candidate", "configuration")})
        snapshot.update(schema=1, mode="demo", transport="controlled-http-simulated",
                        databasePath=container + "/Documents/ocean_delivery-demo.sqlite",
                        launchConfigPath=launch["launch_config"]["path"], launchConfigByteLength=321,
                        launchConfigSchema=1, observedAt="2026-10-10T10:00:02Z",
                        model={"initialized": True, "queueCount": 1},
                        camera={"latitude": -33.87, "longitude": 151.21, "zoom": 16.0})
        snapshot["persistedStops"][0].update(status="completed", operationId="operation-fixture", recordedAt="2023-11-14T22:13:20.000Z")
        snapshot["stops"] = copy.deepcopy(snapshot["persistedStops"])
        snapshot["outbox"] = [{"seq": 7, "operationId": "operation-fixture", "datasetId": "dataset-fixture",
                               "stopId": "stop-fixture", "status": "completed", "reason": None,
                               "note": None, "recordedAt": "2023-11-14T22:13:20.000Z"}]
        snapshot["persistedSettings"].update(online=False, viewport={"datasetId": "dataset-fixture", "latitude": -33.87, "longitude": 151.21, "zoom": 16.0})
        offline = copy.deepcopy(snapshot)
        offline["observedAt"] = "2026-10-10T10:00:01Z"
        offline["persistedSettings"]["viewport"]["zoom"] = 15.0
        offline["camera"]["zoom"] = 15.0
        artifact("saved/snapshot.json", "driver-raw-evidence", snapshot)
        artifact("saved/result.json", "driver-raw-evidence", {**launch, "schema": 1, "revision": 6,
                 "status": "passed", "scope": "e08-native-functional-acceptance", "vmProcessId": 101})
        artifact("saved/observations.jsonl", "driver-raw-evidence", "\n".join(json.dumps(row) for row in (offline, snapshot)) + "\n")
        artifact("saved/phase-final.sqlite.json", "sqlite-projection", {
            "path": "phase-final.sqlite", "sha256": sql["sha256"], "user_version": 2,
            "tables": database["tables"], "schema": database["schema"], "triggers": database["triggers"],
            "sqlite_sequence": [{"name": name, "seq": seq} for name, seq in sorted(database["sequences"].items())],
        })
        artifact("saved/phase-final.journal.jsonl", "repository-coordinator-journal", json.dumps({
            **{key: launch[key] for key in ("processId", "session", "candidate", "configuration")},
            "source": "repository", "stage": "submit_committed",
        }) + "\n")
        nearest_artifacts = {
            "observations": artifact("saved/nearest-observations.jsonl", "driver-raw-evidence", json.dumps({"observedAt": "2026-10-10T10:00:05Z", "model": {"panel": "map", "selected": None}}) + "\n"),
            "actions": artifact("saved/nearest-actions.jsonl", "driver-raw-evidence", json.dumps({"observedAt": "2026-10-10T10:00:05Z", "action": "tap:detail-close", "stage": "completed"}) + "\n"),
        }
        body = {key: snapshot["outbox"][0][key] for key in ("operationId", "datasetId", "stopId", "status", "reason", "note", "recordedAt")}
        fixture = artifact("fixture-requests.jsonl", "task-controlled-requests", "\n".join(json.dumps(row) for row in (
            {"kind": "sync", "seq": 1, "body": body},
            {"kind": "sync-response", "requestSeq": 1, "emitted": True, "ack": {key: body[key] for key in ("operationId", "datasetId", "stopId")}},
        )) + "\n")
        collector = {"schema": 1, "status": "passed", "candidate": self.fingerprint,
                     "configuration": "demo", "platform": "ios", "entrypoint": "integration_test/workbench_entry.dart",
                     "scope": "workbench-tooling-smoke", "business_acceptance": False,
                     "data_container": container, "launches": launches, "artifacts": refs}
        item = validator.raw(self.evidence(owner.name + "/result.json", "raw-native-collector", json.dumps(collector)))
        inventory = validator.native_inventory(item)
        run = {**collector, "_evidence_owner": owner, "_collector_item": item,
               "_verified_artifacts": {name: ref["sha256"] for name, ref in inventory.items()}}
        recovered = copy.deepcopy(snapshot)
        recovered.update({key: launches[1][key] for key in ("processId", "session", "candidate", "configuration")})
        recovered["observedAt"] = "2026-10-10T10:00:03Z"
        checked = {name: {"run": run} for name in ("N1.first-import", "N1.no-resend")}
        checked["N1.offline-two-results"] = {"run": run, "after": offline}
        checked["N1.cold-preservation"] = {"run": run, "after": recovered}
        checked["N1.serial-confirmation"] = {"run": run, "check": {"fixture": "requests"},
                                             "artifacts": {"requests": fixture}, "journal": [{"stage": "ack_committed", "operationId": "operation-fixture"}]}
        checked["N4.reference-nearest"] = {"check": {"observations": "observations", "actions": "actions"},
                                           "artifacts": nearest_artifacts, "after": {"observedAt": "2026-10-10T10:00:04Z"}}
        return validator, checked

    def test_cold_preservation_uses_genuine_phase_end_after_later_camera_change(self):
        validator, checked = self.saved_phase_fixture()
        self.assertEqual(checked["N1.offline-two-results"]["after"]["persistedSettings"]["viewport"]["zoom"], 15.0)
        baseline = validator.native_saved_baseline(checked["N1.offline-two-results"])
        self.assertEqual(baseline["persistedSettings"]["viewport"]["zoom"], 16.0)
        validator.native_cross_checks(checked)

    def test_cold_preservation_still_rejects_changed_full_state_and_wrong_installation(self):
        for field, mutation in (
            ("persistedSettings", lambda s: s["persistedSettings"]["viewport"].update(zoom=15.0)),
            ("outbox", lambda s: s["outbox"][0].update(operationId="changed")),
            ("persistedStops", lambda s: s["persistedStops"][0].update(address="lost full address")),
            ("stops", lambda s: s["stops"].clear()),
        ):
            with self.subTest(field=field):
                validator, checked = self.saved_phase_fixture()
                mutation(checked["N1.cold-preservation"]["after"])
                with self.assertRaisesRegex(EvidenceError, "actual cold preserved " + field):
                    validator.native_cross_checks(checked)
        validator, checked = self.saved_phase_fixture()
        checked["N1.cold-preservation"]["run"] = {**checked["N1.cold-preservation"]["run"], "data_container": "another-install"}
        with self.assertRaisesRegex(EvidenceError, "same actual installation/run"):
            validator.native_cross_checks(checked)

    def test_saved_baseline_rejects_unbound_or_edited_endpoints_and_wrong_phase_identity(self):
        for change, message in (
            (lambda v: v["run"]["_verified_artifacts"].pop(str(v["run"]["_evidence_owner"] / "saved/snapshot.json")), "original collector binding"),
            (lambda v: (v["run"]["_evidence_owner"] / "saved/snapshot.json").write_text("{}"), "sha256 mismatch"),
            (lambda v: v["after"].update(processId=102), "processId identity"),
            (lambda v: v["after"].update(session="session-recovered"), "session identity"),
            (lambda v: v["after"].update(configuration="local-client"), "configuration identity"),
            (lambda v: v["after"].update(observedAt="2026-10-10T10:00:09Z"), "precedes offline result"),
        ):
            with self.subTest(message=message):
                validator, checked = self.saved_phase_fixture()
                value = checked["N1.offline-two-results"]
                change(value)
                with self.assertRaisesRegex(EvidenceError, message):
                    validator.native_saved_baseline(value)

    def rewrite_phase_evidence(self, validator, value, name, mutation):
        """Hash-valid negative fixture changes, not a real acceptance receipt."""
        run = value["run"]
        owner = run["_evidence_owner"]
        path = owner / name
        document = json.loads(path.read_bytes())
        mutation(document)
        raw = json.dumps(document).encode()
        path.write_bytes(raw)
        collector = json.loads(run["_collector_item"]["raw"])
        next(ref for ref in collector["artifacts"] if ref["path"] == name)["sha256"] = hashlib.sha256(raw).hexdigest()
        collector_path = run["_collector_item"]["path_object"]
        raw_collector = json.dumps(collector).encode()
        collector_path.write_bytes(raw_collector)
        run["_collector_item"] = validator.raw({"path": str(collector_path), "kind": "raw-native-collector", "sha256": hashlib.sha256(raw_collector).hexdigest()})
        run["artifacts"] = collector["artifacts"]
        run["_verified_artifacts"][str(path)] = hashlib.sha256(raw).hexdigest()

    def test_hash_valid_saved_snapshot_still_requires_actual_sql_and_phase_identity(self):
        for name, mutation, message in (
            ("saved/snapshot.json", lambda s: s.update(processId=102), "processId identity"),
            ("saved/snapshot.json", lambda s: s.update(databasePath="/another-app/ocean_delivery-demo.sqlite"), "databasePath"),
            ("saved/result.json", lambda r: r.update(vmProcessId=102), "vmProcessId identity"),
            ("saved/result.json", lambda r: r.update(status="failed"), "status must be 'passed'"),
            ("saved/phase-final.sqlite.json", lambda p: p["tables"]["delivery_settings"][0].update(viewport_zoom=17.0), "actual SQL projection tables"),
        ):
            with self.subTest(name=name, message=message):
                validator, checked = self.saved_phase_fixture()
                value = checked["N1.offline-two-results"]
                self.rewrite_phase_evidence(validator, value, name, mutation)
                with self.assertRaisesRegex(EvidenceError, message):
                    validator.native_saved_baseline(value)
        validator, checked = self.saved_phase_fixture()
        value = checked["N1.offline-two-results"]
        collector = json.loads(value["run"]["_collector_item"]["raw"])
        owner = value["run"]["_evidence_owner"]
        (owner / "saved/initial-snapshot.json").write_bytes((owner / "saved/snapshot.json").read_bytes())
        next(ref for ref in collector["artifacts"] if ref["path"] == "saved/snapshot.json")["path"] = "saved/initial-snapshot.json"
        original = value["run"]["_collector_item"]
        raw = json.dumps(collector).encode()
        original["path_object"].write_bytes(raw)
        value["run"]["_collector_item"] = validator.raw({"path": str(original["path_object"]), "kind": original["kind"], "sha256": hashlib.sha256(raw).hexdigest()})
        with self.assertRaisesRegex(EvidenceError, "exactly one saved/snapshot.json"):
            validator.native_saved_baseline(value)

    def migration_retry_fixture(self):
        path = self.root / "legacy-retry.sqlite"
        with sqlite3.connect(path) as connection:
            connection.executescript("""
                PRAGMA user_version=1;
                CREATE TABLE datasets(id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE stops(id TEXT PRIMARY KEY, dataset_id TEXT, reference TEXT,
                    customer_name TEXT,address TEXT,latitude REAL,longitude REAL,status TEXT,
                    reason TEXT,operation_id TEXT,acknowledged_at INTEGER);
                CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT,dataset_id TEXT,stop_id TEXT,status TEXT,reason TEXT);
                INSERT INTO datasets VALUES ('legacy-dataset');
                INSERT INTO stops VALUES ('legacy-stop','legacy-dataset','native-fixture',
                    'Legacy','Legacy address',0,0,'failed','  Historical reason  ','legacy-op',NULL);
                INSERT INTO outbox VALUES (7,'legacy-op','legacy-dataset','legacy-stop','failed','  Historical reason  ');
                INSERT INTO outbox VALUES (22,'deleted-op','legacy-dataset','legacy-stop','completed',NULL);
                DELETE FROM outbox WHERE seq=22;
            """)
        validator = Validator(self.manifest, self.fingerprint, self.root)
        legacy = validator.raw(self.evidence("legacy-before.sqlite", "sqlite-backup", path.read_bytes()))
        rollback = validator.raw(self.evidence("legacy-rollback.sqlite", "sqlite-backup", path.read_bytes()))
        with sqlite3.connect(path) as connection:
            connection.executescript("""
                ALTER TABLE stops ADD COLUMN time_window TEXT;
                ALTER TABLE stops ADD COLUMN note TEXT;
                ALTER TABLE stops ADD COLUMN recorded_at INTEGER;
                ALTER TABLE outbox ADD COLUMN note TEXT;
                ALTER TABLE outbox ADD COLUMN recorded_at INTEGER;
                CREATE TABLE delivery_settings(dataset_id TEXT PRIMARY KEY,online INTEGER,
                    viewport_latitude REAL,viewport_longitude REAL,viewport_zoom REAL);
                PRAGMA user_version=2;
            """)
        upgraded = validator.raw(self.evidence("legacy-upgraded.sqlite", "sqlite-backup", path.read_bytes()))
        identity = {"processId": 101, "candidate": self.fingerprint, "configuration": "demo", "session": "migration-session"}
        failed = validator.raw(self.evidence("migration-failed.json", "failed-boot-snapshot", json.dumps({**identity, "model": {"initialized": False}, "outbox": None})))
        return validator, {"check": {**identity, "id": "N6.migration-rollback-retry", "transport": "controlled-http-simulated",
                                     "legacy_before_sqlite": "legacy", "rollback_sqlite": "rollback", "rollback_snapshot": "failed"},
                           "before": {}, "after": {"model": {}}, "database": validator.database(upgraded),
                           "artifacts": {"legacy": legacy, "rollback": rollback, "failed": failed},
                           "actions": ["tap:reload-data"], "journal": [{"stage": "initialize_failed"}]}

    def test_migration_retry_uses_actual_reload_action_and_preserves_raw_rollback_guards(self):
        validator, value = self.migration_retry_fixture()
        validator.native_minimum(value)
        value["actions"] = ["tap:retry-bootstrap"]
        with self.assertRaisesRegex(EvidenceError, "actual UI tap reload-data"):
            validator.native_minimum(value)
        value["actions"] = ["tap:reload-data"]
        value["database"]["tables"]["outbox"][0]["reason"] = "lost historical reason"
        with self.assertRaisesRegex(EvidenceError, "legacy immutable reason"):
            validator.native_minimum(value)
        value["database"]["tables"]["outbox"][0]["reason"] = "  Historical reason  "
        path = value["artifacts"]["rollback"]["path_object"]
        with sqlite3.connect(path) as connection:
            connection.execute("UPDATE stops SET reason='changed during failed migration'")
        raw = path.read_bytes()
        value["artifacts"]["rollback"] = validator.raw({"path": str(path), "kind": "sqlite-backup", "sha256": hashlib.sha256(raw).hexdigest()})
        with self.assertRaisesRegex(EvidenceError, "rollback preserves v1 tables"):
            validator.native_minimum(value)

    def test_complete_synthetic_fixture_only_validates_schema(self):
        # A complete full-quality schema can pass its own validator. The old
        # platform/restart-only native fixture remains insufficient for G2.
        validator = Validator(self.manifest, self.fingerprint, self.root)
        item = next(item for item in self.entry("G1")["evidence"] if item["kind"] == "quality-run")
        self.assertEqual(validator.quality(self.quality, validator.raw(item)), self.quality)
        self.assert_rejected("native acceptance schema")

    def test_every_required_capability_and_gate_rejects_missing_entry(self):
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                with self.subTest(entry_id=entry_id):
                    manifest = copy.deepcopy(self.manifest)
                    del manifest[group][entry_id]
                    self.assert_rejected(f"{group}.{entry_id} is missing", manifest)

    def test_every_required_status_rejects_unknown_failed_skipped_and_stale(self):
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                for status in ("unknown", "failed", "skipped", "stale", "partial", "not_applicable"):
                    with self.subTest(entry_id=entry_id, status=status):
                        manifest = copy.deepcopy(self.manifest)
                        manifest[group][entry_id]["status"] = status
                        self.assert_rejected(f"{group}.{entry_id}.status", manifest)

    def test_candidate_changes_invalidate_all_old_evidence(self):
        self.assert_rejected("candidate.source_fingerprint", fingerprint="b" * 64)
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                with self.subTest(entry_id=entry_id):
                    manifest = copy.deepcopy(self.manifest)
                    manifest[group][entry_id]["candidate"] = "old-source"
                    self.assert_rejected(f"{group}.{entry_id}.candidate", manifest)

    def test_missing_evidence_unknown_files_and_hash_mismatch_fail(self):
        for evidence, expected in (
            ([], "evidence is missing"),
            ([{"path": "gone.log", "kind": "raw-log", "sha256": "0"}], "SHA-256"),
            ([{"path": "H01.log", "kind": "raw-log", "sha256": "0"}], "SHA-256"),
            ([{"path": "H01.log", "sha256": "0"}], "requires path, sha256 and kind"),
        ):
            with self.subTest(expected=expected):
                manifest = copy.deepcopy(self.manifest)
                manifest["harness"]["H01"]["evidence"] = evidence
                self.assert_rejected(expected, manifest)

    def test_claimed_enforcement_does_not_override_missing_ci_or_release_proof(self):
        self.manifest["enforcement_deployed"] = False
        self.assert_rejected("enforcement_deployed")
        self.manifest["enforcement_deployed"] = True
        for kind in ("ci-enforcement", "release-enforcement"):
            with self.subTest(kind=kind):
                self.change_report("H06", kind, {"enforced": False})
                self.assert_rejected("enforced must be True")
                self.change_report("H06", kind, {"enforced": True})
        self.entry("H06")["evidence"] = [self.entry("H06")["evidence"][0]]
        self.assert_rejected("H06 requires valid ci-enforcement")

    def test_passed_envelope_cannot_override_failed_stale_or_incomplete_quality(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        for change, expected in (
            (lambda r: r.update(candidate={"source_fingerprint": "old-source"}), "candidate is missing or stale"),
            (lambda r: r.update(candidate_after={"source_fingerprint": "changed-source"}), "candidate_after is missing or stale"),
            (lambda r: r.update(job={"status": "failed"}), "job.status must be 'passed'"),
            (lambda r: r.update(command="test"), "command must be 'quality'"),
            (lambda r: r.update(stages=r["stages"][:-1]), "required quality stages"),
            (lambda r: r["stages"][4].update(status="failed", exit_code=1), "stage status"),
        ):
            with self.subTest(expected=expected):
                report = copy.deepcopy(self.quality)
                change(report)
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected(expected)

    def test_quality_requires_original_stage_logs_and_quality_report_kind(self):
        log = self.root / self.quality["stages"][0]["log_path"]
        log.write_text("changed after the run")
        self.assert_rejected("sha256 mismatch")
        log.unlink()
        self.assert_rejected("cannot read")
        self.entry("G1")["evidence"] = [self.entry("G1")["evidence"][0]]
        self.assert_rejected("G1 requires valid quality-run")

    def test_browser_host_and_hot_restart_do_not_pass_native_gate(self):
        for changes, expected in (
            ({"platform": "browser"}, "platform must be android or ios"),
            ({"platform": "host"}, "platform must be android or ios"),
            ({"platform": "android", "process_restart": False}, "process_restart must be True"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G2", "native-acceptance", changes)
                self.assert_rejected(expected)

    def test_debug_emulator_and_simulator_cannot_pass_real_profile_gate(self):
        for changes, expected in (
            ({"build_mode": "debug"}, "build_mode must be 'profile'"),
            ({"build_mode": "release"}, "build_mode must be 'profile'"),
            ({"build_mode": "profile", "device_type": "emulator"}, "device_type must be 'real'"),
            ({"device_type": "simulator"}, "device_type must be 'real'"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G3", "performance", changes)
                self.assert_rejected(expected)

    def test_fake_sync_cannot_pass_connected_delivery(self):
        self.change_report("G4", "connected-service", {"transport": "fake"})
        self.assert_rejected("transport must be 'connected'")
        item = next(value for value in self.entry("G4")["evidence"] if value["kind"] == "connected-service")
        item["kind"] = "fake-sync"
        self.assert_rejected("G4 requires valid connected-service")

    def test_raw_specialized_report_candidate_and_status_are_checked(self):
        for changes, expected in (
            ({"candidate": "old-source"}, "candidate must be"),
            ({"candidate": self.fingerprint, "status": "failed"}, "status must be 'passed'"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G3", "performance", changes)
                self.assert_rejected(expected)

    def test_specialized_evidence_must_be_raw_json(self):
        item = next(value for value in self.entry("G3")["evidence"] if value["kind"] == "performance")
        (self.root / item["path"]).write_text("reported passed, raw report unavailable")
        item["sha256"] = hashlib.sha256((self.root / item["path"]).read_bytes()).hexdigest()
        self.assert_rejected("expected a raw JSON report")

    def test_release_requires_release_mode_production_signature_and_artifact_hash(self):
        for changes, expected in (
            ({"build_mode": "debug"}, "build_mode must be 'release'"),
            ({"build_mode": "release", "signed": False}, "signed must be True"),
            ({"signed": True, "signing_kind": "debug"}, "signing_kind must be 'production'"),
            ({"signing_kind": "production", "artifact_sha256": "wrong"}, "artifact_sha256 does not match"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G5", "release-signature", changes)
                self.assert_rejected(expected)

    def test_delivery_requires_authorization_matching_destination_and_artifact(self):
        self.change_report("G6", "authorization-receipt", {"authorized": False})
        self.assert_rejected("authorized must be True")
        self.change_report("G6", "authorization-receipt", {"authorized": True})
        for changes, expected in (
            ({"delivered": False}, "delivered must be True"),
            ({"delivered": True, "destination": "synthetic://unauthorized"}, "no matching authorization"),
            ({"destination": "synthetic://test", "artifact_sha256": "wrong"}, "artifact_sha256 does not match"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G6", "delivery-receipt", changes)
                self.assert_rejected(expected)

    def test_delivery_cannot_select_an_unsigned_second_artifact(self):
        unsigned = self.evidence("unsigned.bin", "release-artifact", b"unsigned second fixture")
        self.entry("G5")["evidence"].append(unsigned)
        self.change_report("G6", "delivery-receipt", {"artifact_sha256": unsigned["sha256"]})
        self.assert_rejected("no matching production signature")

    def test_full_quality_rejects_bool_exit_targeted_command_old_inputs_and_incomplete_cleanup(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        mutations = (
            (lambda r: r["stages"][0].update(exit_code=False), "booleans"),
            (lambda r: r["options"].update(targets=["test/review/one.dart"]), "full-suite targets"),
            (lambda r: r["inputs"].update(lock_sha256="0" * 64), "current source input"),
            (lambda r: r["isolation"].update(cleaned=False), "isolation.cleaned"),
            (lambda r: r.update(execution_candidate_after={"source_fingerprint": "b" * 64}), "execution_candidate_after"),
            (lambda r: r["stages"][6]["command"].append("--plain-name=one"), "full quality stage command"),
        )
        for mutation, text in mutations:
            with self.subTest(text=text):
                report = copy.deepcopy(self.quality)
                mutation(report)
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected(text)

    def test_hash_valid_late_flutter_failure_or_truncated_tooling_completion_rejects(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        for stage_id, text in (("flutter-tests", "00:01 +9: All tests passed!\nunhandled exception after completion\n"), ("tooling-tests", "Ran 9 tests in 0.02s\n")):
            with self.subTest(stage=stage_id):
                report = copy.deepcopy(self.quality)
                stage = next(stage for stage in report["stages"] if stage["id"] == stage_id)
                original_log = (self.root / stage["log_path"]).read_bytes()
                (self.root / stage["log_path"]).write_text(text)
                stage["sha256"] = hashlib.sha256(text.encode()).hexdigest()
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected("successful completion")
                (self.root / stage["log_path"]).write_bytes(original_log)

    def test_hash_valid_quality_requires_typed_complete_stage_reaping(self):
        # Actual 075012 producer completion fields, with synthetic PIDs/logs so
        # this regression stays portable and never adopts ignored run evidence.
        mutations = {
            "missing receipt": lambda s: s.pop("completion"),
            "nonobject receipt": lambda s: s.update(completion=[]),
            "missing group state": lambda s: s["completion"].pop("group_alive"),
            "unreaped live group": lambda s: s["completion"].update(wrapper_reaped=False, returncode=None, group_alive=True, cleanup_errors=["still running"]),
            "not spawned": lambda s: s["completion"].update(spawned=False),
            "numeric spawned": lambda s: s["completion"].update(spawned=1),
            "wrong wrapper": lambda s: s["completion"].update(wrapper_pid=100),
            "wrong group": lambda s: s["completion"].update(process_group=100),
            "boolean wrapper": lambda s: s.update(job_pid=1, completion={**s["completion"], "wrapper_pid": True, "process_group": 1}),
            "boolean group": lambda s: s.update(job_pid=1, completion={**s["completion"], "wrapper_pid": 1, "process_group": True}),
            "numeric reaped": lambda s: s["completion"].update(wrapper_reaped=1),
            "nonzero child": lambda s: s["completion"].update(returncode=1),
            "boolean returncode": lambda s: s["completion"].update(returncode=False),
            "live group": lambda s: s["completion"].update(group_alive=True),
            "numeric group state": lambda s: s["completion"].update(group_alive=0),
            "unknown group state": lambda s: s["completion"].update(group_alive=None),
            "cleanup error": lambda s: s["completion"].update(cleanup_errors=[{"type": "OSError", "message": "incomplete"}]),
            "untyped empty errors": lambda s: s["completion"].update(cleanup_errors=""),
            "unknown cleanup errors": lambda s: s["completion"].update(cleanup_errors=None),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                report = copy.deepcopy(self.quality)
                mutate(report["stages"][0])
                # Both report and all original logs have valid hashes: refusal
                # must come from missing/contradictory facts, not a hash error.
                ref = self.evidence("completion-mutated-quality.json", "quality-run", json.dumps(report))
                validator = Validator(self.manifest, self.fingerprint, self.root)
                with self.assertRaisesRegex(EvidenceError, "stage completion"):
                    validator.quality(report, validator.raw(ref))

    def quality_with_tooling(self, text):
        """Exercise the full original-log/hash reader, not only a regex helper."""
        report = copy.deepcopy(self.quality)
        stage = next(stage for stage in report["stages"] if stage["id"] == "tooling-tests")
        (self.root / stage["log_path"]).write_text(text)
        stage["sha256"] = hashlib.sha256(text.encode()).hexdigest()
        item = self.evidence("tooling-completion-quality.json", "quality-run", json.dumps(report))
        validator = Validator(self.manifest, self.fingerprint, self.root)
        return validator.quality(report, validator.raw(item))

    def test_quality_accepts_only_exact_counted_platform_skip_with_complete_verbose_rows(self):
        text = (
            "test_every_required_status_rejects_unknown_failed_skipped_and_stale (test_gate.GateTests.test_every_required_status_rejects_unknown_failed_skipped_and_stale) ... ok\n"
            "test_invalid_cli (test_runner.RunnerTests.test_invalid_cli) ... usage: expected captured stderr\n"
            "error: intentionally rejected fixture argument\nok\n"
            "test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean (test_state.StateTests.test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean) ... skipped 'Linux task subreaper observes an actual unreaped orphan'\n"
            "\n----------------------------------------------------------------------\nRan 3 tests in 0.02s\n\nOK (skipped=1)\n"
        )
        self.assertEqual(self.quality_with_tooling(text)["command"], "quality")

    def test_quality_keeps_complete_linux_zero_skip_and_rejects_missing_rows(self):
        text = (
            "test_every_required_status_rejects_unknown_failed_skipped_and_stale (test_gate.GateTests.test_every_required_status_rejects_unknown_failed_skipped_and_stale) ... ok\n"
            "test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean (test_state.StateTests.test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean) ... ok\n"
            "\n----------------------------------------------------------------------\nRan 2 tests in 0.02s\n\nOK\n"
        )
        self.assertEqual(self.quality_with_tooling(text)["command"], "quality")
        variants = {
            "summary only": "Ran 2 tests in 0.02s\n\nOK\n",
            "one missing row": text.replace("test_every_required_status_rejects_unknown_failed_skipped_and_stale (test_gate.GateTests.test_every_required_status_rejects_unknown_failed_skipped_and_stale) ... ok\n", ""),
            "inflated count": text.replace("Ran 2", "Ran 161"),
            "truncated outcome": text.replace(" ... ok\n", " ...\n", 1),
        }
        for label, raw in variants.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(EvidenceError, "tooling-tests raw log lacks final successful completion"):
                    self.quality_with_tooling(raw)

    def test_quality_rejects_hash_valid_skip_identity_count_failure_and_truncation(self):
        row = "test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean (test_state.StateTests.test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean) ... skipped 'Linux task subreaper observes an actual unreaped orphan'\n"
        other = "test_product (test_delivery.DeliveryTests.test_product) ... ok\n"
        valid = row + other + "\n----------------------------------------------------------------------\nRan 2 tests in 0.02s\n\nOK (skipped=1)\n"
        variants = {
            "unknown skipped product": valid.replace(row, "test_product (test_delivery.DeliveryTests.test_product) ... skipped 'not available'\n"),
            "wrong zombie class": valid.replace("test_state.StateTests", "other.StateTests"),
            "wrong skip reason": valid.replace("Linux task subreaper observes an actual unreaped orphan", "platform unsupported"),
            "duplicate singleton": valid.replace(other, row),
            "two declared skips": valid.replace(other, row).replace("skipped=1", "skipped=2"),
            "counted missing row": valid.replace("Ran 2", "Ran 3"),
            "declared zero": valid.replace("skipped=1", "skipped=0"),
            "undeclared skip": valid.replace("OK (skipped=1)", "OK"),
            "declared without row": valid.replace(row, row.replace("skipped 'Linux task subreaper observes an actual unreaped orphan'", "ok")),
            "truncated verbose row": valid.replace(other, other.replace(" ... ok", " ...")),
            "empty verbose outcome": valid.replace(other, other.replace("ok\n", "\n")),
            "unknown outcome": valid.replace(other, other.replace("ok\n", "not_run\n")),
            "multiline product skip with allowed reason": valid.replace(other, "test_product (test_delivery.DeliveryTests.test_product) ... captured stderr\nskipped 'Linux task subreaper observes an actual unreaped orphan'\n"),
            "known skip continued as successful result": valid.replace(row, row + "ok\n"),
            "failed row": valid.replace(other, other.replace("ok\n", "FAIL\n")),
            "error row": valid.replace(other, other.replace("ok\n", "ERROR\n")),
            "expected failure row": valid.replace(other, other.replace("ok\n", "expected failure\n")),
            "unexpected success row": valid.replace(other, other.replace("ok\n", "unexpected success\n")),
            "expected failure footer": valid.replace("skipped=1", "skipped=1, expected failures=1"),
            "truncated footer": valid.replace("OK (skipped=1)\n", "OK (skipped=1"),
            "late error": valid + "RuntimeError after completion\n",
            "background exception": valid.replace("Ran 2", "Exception in thread fixture\nRan 2"),
        }
        for label, text in variants.items():
            with self.subTest(label=label):
                with self.assertRaisesRegex(EvidenceError, "tooling-tests raw log lacks final successful completion"):
                    self.quality_with_tooling(text)

    def test_local_evaluator_never_returns_a_production_allowed_field(self):
        self.manifest["delivery_scope"] = "local-demo"
        self.manifest["enforcement_deployed"] = False
        result = evaluate_local(self.manifest, self.fingerprint, self.root)
        self.assertEqual(set(result), {"local_allowed", "publish_allowed", "reasons"})
        self.assertIs(result["publish_allowed"], False)
        self.assertIs(result["local_allowed"], False)  # bare G2/tooling smoke
        self.assertTrue(any("native acceptance schema" in reason for reason in result["reasons"]))
        self.assert_rejected("enforcement_deployed")

    def test_malformed_top_level_types_return_structured_refusal(self):
        for manifest in (None, [], True, {"candidate": False}, {"candidate": {"source_fingerprint": self.fingerprint}, "service_mode": True}):
            with self.subTest(manifest=manifest):
                self.assertFalse(evaluate(manifest, self.fingerprint, self.root)["allowed"])
                local = evaluate_local(manifest, self.fingerprint, self.root)
                self.assertFalse(local["local_allowed"])
                self.assertIs(local["publish_allowed"], False)

    def test_scope_name_cannot_bypass_production_requirements(self):
        self.manifest["delivery_scope"] = "local-demo"
        self.manifest["gates"]["G3"]["status"] = "not_applicable"
        self.assert_rejected("gates.G3.status")


if __name__ == "__main__":
    unittest.main()
